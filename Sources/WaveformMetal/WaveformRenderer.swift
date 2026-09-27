//
//  WaveformRenderer.swift
//
//  MTKView の描画、LOD ごとの頂点バッファ、描画統計を管理する。
//  再生時計と PCM 解析は利用側が担当し、レンダラーは各フレームの入力を受け取る。
//
//  更新のタイミング:
//    - 解析結果の設定時: 既存の頂点バッファと取得時刻の履歴を破棄する。
//    - LOD の初回使用時: 描画中に頂点配列と MTLBuffer を構築する。
//    - 毎フレーム: 入力取得、カメラと LOD の選択、可視範囲と描画命令の更新を行う。
//
//  頂点はトラックの時刻と振幅を保持し、GPU が画面座標へ変換する。
//  解析結果が同じ間は、キャッシュ済みの頂点をスクロールやズームで再構築しない。
//  検証用の rebuildEveryFrame を有効にした場合は、最細 LOD を毎フレーム再構築する。
//

import Foundation
import Metal
import MetalKit
import QuartzCore
import WaveformCore

// MARK: - レンダラー本体

/// MTKView の delegate として波形シーンを毎フレーム描画する。
///
/// 描画と入力 provider、統計通知は MainActor 上で扱う。利用側も同じ分離に従う。
/// 独自の MTKView を接続する場合は、描画先の形式を bgra8Unorm、
/// サンプル数を `rasterSampleCount` に揃える。
@MainActor
public final class WaveformRenderer: NSObject, MTKViewDelegate {

    // MARK: 定数

    /// ズーム 1 倍で画面幅に収める時間（秒）。
    public static let viewportSecondsAtZoom1: Double = 16.0

    /// 輪郭のギザつきを抑える MSAA のサンプル数。細かな周期模様のちらつきは残り得る。
    /// MTKView.sampleCount と必ず一致させること（WaveformMetalView 参照）。
    public static let rasterSampleCount = 4

    /// LOD 選択のオーバーサンプリング係数。
    /// 1px あたり 2 バケットを目標に選択し、細部のつぶれを抑える。
    /// 最細レベルの解像度を超える拡大では、この密度には届かない。
    public static let lodOversampling = 2.0

    /// 振幅 -1...1 を NDC Y に写す倍率（上下に 15% の余白を残す）
    private static let amplitudeScale: Float = 0.85

    /// 統計の集計窓（秒）
    private static let statsWindowSec: Double = 0.5

    // MARK: 外部から与えられる状態

    /// 描画する解析結果。代入のたびに全 LOD のバッファと入力時刻の履歴を破棄する。
    /// SwiftUI の更新や毎フレームの処理から同じ値を繰り返し代入しない。
    /// nil またはレベルが空の場合は、描画コマンドを送信しない。
    public var analysis: WaveformAnalysis? {
        didSet { resetLevelCaches() }
    }

    /// 0 秒を原点とする拍グリッドの間隔（秒）。有限値を渡す。0 以下ならグリッドを描かない。
    /// BPM が既知なら 60 / BPM で求める。拍の検出は利用側で行う。
    public var beatIntervalSec: Double = 0.5
    /// 1 小節あたりの拍数。正の整数を渡す。
    public var beatsPerBar: Int = 4

    /// 各フレームの入力を MainActor 上で一度だけ取得する。
    /// `timedFrameInputProvider` が未設定の場合に使う。解析や I/O などの重い処理は避ける。
    public var frameInputProvider: () -> WaveformFrameInput = { WaveformFrameInput() }

    /// 表示予定のホスト時刻から毎フレームの入力を取得する。設定時はこちらを優先する。
    /// 時刻は CACurrentMediaTime() と同じ基準で、トラック内の秒数ではない。
    /// 呼び出し側で再生時計へ対応付け、その時刻の状態を一度だけ返す。
    public var timedFrameInputProvider: ((CFTimeInterval) -> WaveformFrameInput)?

    /// 約 0.5 秒の集計窓が閉じたときの通知。MainActor 上で呼ぶ。
    /// 描画が止まっている間や描画に失敗したフレームでは通知しない。
    public var onStats: ((RenderStats) -> Void)?

    // MARK: Metal オブジェクト

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    /// 波形本体用（頂点バッファ + time-domain 頂点シェーダ）
    private let waveformPipeline: MTLRenderPipelineState
    /// 縦線マーカー用（頂点バッファなし・vertex_id 合成）
    private let markerPipeline: MTLRenderPipelineState

    /// LOD レベルごとの頂点バッファキャッシュ。
    /// 初めて使うレベルを描画中に構築し、analysis の再代入まで保持する。
    private var levelVertexBuffers: [MTLBuffer?] = []

    private var drawableSize = CGSize(width: 1, height: 1)

    // MARK: 統計の内部状態

    private var statsWindowStart = CACurrentMediaTime()
    private var statsFrameCount = 0
    private var statsCPUTimeSum: Double = 0
    private var statsRebuildCount = 0
    private var peakDriftPx: Double = 0
    private var lastLevelIndex = 0
    private var lastDrawnVertexCount = 0

    // MARK: バグ再現モードの内部状態

    private var playheadSampler = PlayheadSampler()
    private var statsMode: PlayheadProjectionMode?
    private var statsRebuildMode: Bool?
    private var statsCameraMode: Bool?

    // MARK: 配色

    private var waveformColor = SIMD4<Float>(0.30, 0.82, 0.78, 1.0)
    private var beatGridColor = SIMD4<Float>(1.0, 1.0, 1.0, 0.10)
    private var barGridColor = SIMD4<Float>(1.0, 1.0, 1.0, 0.22)
    private var cueColor = SIMD4<Float>(1.0, 0.62, 0.20, 0.95)
    private var playheadColor = SIMD4<Float>(1.0, 0.27, 0.32, 1.0)

    // MARK: - 初期化

    /// デバイスに対応するコマンドキューとパイプラインを作る。
    /// リソースの読み込みや生成に失敗した場合は nil を返す。
    /// 頂点バッファはここでは作らず、各 LOD を描くときに用意する。
    public init?(device: MTLDevice) {
        guard let resources = WaveformRenderResources(
            device: device,
            rasterSampleCount: Self.rasterSampleCount
        ) else {
            return nil
        }
        self.device = device
        commandQueue = resources.commandQueue
        waveformPipeline = resources.waveformPipeline
        markerPipeline = resources.markerPipeline
        super.init()
    }

    // MARK: - MTKViewDelegate

    /// ポイント数とは区別して、描画先のピクセル寸法を記録する。
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    /// 現在のホスト時刻を基準に 1 フレーム描く、MTKViewDelegate の入口。
    /// 表示予定時刻が分かる呼び出し元では `draw(in:atHostTime:)` を使う。
    public func draw(in view: MTKView) {
        draw(in: view, atHostTime: CACurrentMediaTime())
    }

    /// 表示予定のホスト時刻を指定して描画する。
    /// WaveformMetalView は CADisplayLink.targetTimestamp を渡す。
    ///
    /// 入力を一度取得し、グリッド、波形、キュー、再生線の順に描画命令を作る。
    /// drawable や解析結果を利用できない場合は、そのフレームを送信しない。
    /// - Parameters:
    ///   - view: パイプラインと同じピクセル形式・MSAA 設定を持つ描画先。
    ///   - hostTime: CACurrentMediaTime() と同じ時間軸の秒数。トラック時刻ではない。
    ///     非有限値の場合は現在のホスト時刻に置き換える。
    public func draw(in view: MTKView, atHostTime hostTime: CFTimeInterval) {
        let cpuStart = CACurrentMediaTime()
        let presentationTime = hostTime.isFinite ? hostTime : cpuStart
        let input = timedFrameInputProvider?(presentationTime) ?? frameInputProvider()

        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let level = encodeFrame(
                input: input, into: commandBuffer, descriptor: descriptor,
                size: view.drawableSize, atTime: cpuStart
            )
        else {
            return
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        accumulateStats(cpuStart: cpuStart, level: level)
    }

    /// 画面とオフスクリーン検証で同じ描画経路を使う。
    /// 入力は呼び出し側で一度だけ取得済み。ここから状態を読み直さない。
    /// drawable の表示予約と commit は描画先を所有する呼び出し側が行う。
    func encodeFrame(
        input: WaveformFrameInput,
        into commandBuffer: MTLCommandBuffer,
        descriptor: MTLRenderPassDescriptor,
        size: CGSize,
        atTime cpuStart: CFTimeInterval
    ) -> WaveformLODLevel? {
        guard let analysis, !analysis.levels.isEmpty,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return nil
        }
        drawableSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        if statsMode != input.playheadProjection || statsRebuildMode != input.rebuildEveryFrame
            || statsCameraMode != input.unsnappedCamera {
            resetStats(now: cpuStart)
            statsMode = input.playheadProjection
            statsRebuildMode = input.rebuildEveryFrame
            statsCameraMode = input.unsnappedCamera
        }

        // ── カメラ決定 ──
        // viewport は CPU 上の可視範囲の計算に使う。GPU 用 uniform は未丸めの
        // rawViewport から直接ピクセル位置を作り、秒へ戻すときの丸め誤差を避ける。
        let rawViewport = WaveformViewport.centered(
            onPlayheadSec: input.playheadSec,
            viewportSec: Self.viewportSecondsAtZoom1 / max(input.zoomScale, 0.001)
        )
        let viewport = input.unsnappedCamera
            ? rawViewport
            : rawViewport.snappedToPixelGrid(drawableWidthPx: Double(drawableSize.width))
        var viewportUniforms = ViewportUniforms(
            viewport: rawViewport,
            drawableWidthPx: Double(drawableSize.width),
            snap: !input.unsnappedCamera,
            amplitudeScale: Self.amplitudeScale
        )

        // ── LOD 選択と頂点バッファ ──
        let secondsPerPixel = viewport.secondsPerPixel(viewWidthPx: Double(drawableSize.width))
        let levelIndex = analysis.levelIndex(forSecondsPerPixel: secondsPerPixel / Self.lodOversampling)
        let level = analysis.levels[levelIndex]

        if input.rebuildEveryFrame {
            // 検証用の追加負荷。描画に選んだレベルにかかわらず、
            // 最細 LOD の全頂点を毎フレーム作り直す。負荷はトラック長や端末に依存する。
            let finest = analysis.levels[0]
            levelVertexBuffers[0] = makeVertexBuffer(level: finest)
            statsRebuildCount += 1
        }

        if levelVertexBuffers[levelIndex] == nil {
            // 未生成の LOD を初めて描くフレームの負荷になる。
            // メモリ確保に失敗して nil の場合は、次のフレームで再試行する。
            levelVertexBuffers[levelIndex] = makeVertexBuffer(level: level)
            statsRebuildCount += 1
        }

        // ── エンコード（後に描く要素を手前に重ねる）──
        // 頂点バッファ index 1 は全パイプライン共通の viewport uniform。
        // エンコーダのバインディングはパイプライン切替後も維持される。
        encoder.setVertexBytes(&viewportUniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)

        // 小節 / 拍グリッド（最背面）
        encoder.setRenderPipelineState(markerPipeline)
        drawGrid(encoder: encoder, viewport: viewport)

        // 波形本体: 可視バケット範囲だけを 1 回の draw 命令で描く
        if let vertexBuffer = levelVertexBuffers[levelIndex] {
            encoder.setRenderPipelineState(waveformPipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewportUniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            var color = waveformColor
            encoder.setVertexBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)

            // 可視範囲のバケット index を O(1) で求め、±1 バケットの余白を足す。
            // 頂点データ自体は不変のまま、描画レンジだけを動かす。
            let firstBucket = max(level.bucketIndex(forTimeSec: viewport.visibleStartSec) - 1, 0)
            let lastBucket = min(level.bucketIndex(forTimeSec: viewport.visibleEndSec) + 1, level.bucketCount - 1)
            let vertexStart = firstBucket * 2
            let vertexCount = (lastBucket - firstBucket + 1) * 2
            lastDrawnVertexCount = vertexCount
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: vertexStart, vertexCount: vertexCount)
        }

        // キューポイントとプレイヘッド（最前面）。
        // キューは波形と同じ投影を使い、再生線はカメラの丸めから独立させる。
        encoder.setRenderPipelineState(markerPipeline)
        encoder.setVertexBytes(&viewportUniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)

        for cueTime in input.cueTimesSec {
            drawMarker(encoder: encoder, timeSec: cueTime, widthPx: 3, color: cueColor)
        }

        let playheadTime = playheadSampler.sample(playheadSec: input.playheadSec, mode: input.playheadProjection, now: cpuStart)
        // 大きな絶対時刻を Float へ変換する前に差を取り、遅延モードの変位を保つ。
        // synced では差が 0 になり、ズームやカメラの丸めによらず中央へ固定される。
        let playheadCenterNDC = Float((playheadTime - input.playheadSec) / rawViewport.viewportSec * 2)
        drawPlayhead(encoder: encoder, centerNDC: playheadCenterNDC)
        peakDriftPx = max(peakDriftPx, driftPx(correct: input.playheadSec, drawn: playheadTime, viewport: viewport))

        encoder.endEncoding()
        lastLevelIndex = levelIndex
        return level
    }

    // MARK: - プレイヘッド投影（正しい実装とバグ再現）

    /// 現在と取得済みの入力時刻を CPU で投影した差を返す（drawable ピクセル）。
    /// 描画結果を読み戻した測定値ではない。ラスタライズや音声出力の誤差は含まない。
    private func driftPx(correct: Double, drawn: Double, viewport: WaveformViewport) -> Double {
        let deltaNDC = Double(viewport.ndcX(forTimeSec: correct) - viewport.ndcX(forTimeSec: drawn))
        // NDC の全幅 2.0 が drawableWidth px に対応する
        return abs(deltaNDC) * Double(drawableSize.width) * 0.5
    }

    // MARK: - 描画ヘルパ

    /// 幅 3 drawable ピクセルの再生線を画面座標で描く。波形・キューの投影は変更しない。
    private func drawPlayhead(encoder: MTLRenderCommandEncoder, centerNDC: Float) {
        var marker = MarkerUniforms(
            timeSec: 0,
            intervalSec: 0,
            halfWidthNDC: Float(3 / Double(drawableSize.width)),
            topNDC: 1,
            bottomNDC: -1,
            screenCenterNDC: centerNDC,
            usesScreenPosition: 1
        )
        var markerColor = playheadColor
        encoder.setVertexBytes(&marker, length: MemoryLayout<MarkerUniforms>.stride, index: 2)
        encoder.setVertexBytes(&markerColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 時刻と幅（drawable ピクセル）を指定して、縦線マーカーを 1 本描く。
    /// マーカーの uniform と色を渡し、シェーダが vertex_id から 4 頂点の矩形を作る。
    private func drawMarker(
        encoder: MTLRenderCommandEncoder,
        timeSec: Double,
        widthPx: Double,
        color: SIMD4<Float>
    ) {
        var marker = MarkerUniforms(
            timeSec: Float(timeSec),
            intervalSec: 0,
            halfWidthNDC: Float(widthPx / Double(drawableSize.width)),
            topNDC: 1,
            bottomNDC: -1
        )
        var markerColor = color
        encoder.setVertexBytes(&marker, length: MemoryLayout<MarkerUniforms>.stride, index: 2)
        encoder.setVertexBytes(&markerColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 可視範囲の拍線・小節線をインスタンス描画する。
    /// CPU で先頭時刻と本数を計算して描画命令を作り、各線の座標はシェーダで求める。
    private func drawGrid(encoder: MTLRenderCommandEncoder, viewport: WaveformViewport) {
        guard beatIntervalSec > 0 else { return }

        func drawLines(intervalSec: Double, widthPx: Double, color: SIMD4<Float>) {
            let firstIndex = Int(floor(viewport.visibleStartSec / intervalSec))
            let lastIndex = Int(ceil(viewport.visibleEndSec / intervalSec))
            let count = lastIndex - firstIndex + 1
            // 異常なズーム値で数万インスタンスを発行しないための上限
            guard count > 0, count < 4096 else { return }
            var marker = MarkerUniforms(
                timeSec: Float(Double(firstIndex) * intervalSec),
                intervalSec: Float(intervalSec),
                halfWidthNDC: Float(widthPx / Double(drawableSize.width)),
                topNDC: 1,
                bottomNDC: -1
            )
            var markerColor = color
            encoder.setVertexBytes(&marker, length: MemoryLayout<MarkerUniforms>.stride, index: 2)
            encoder.setVertexBytes(&markerColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }

        // 拍線は間隔が 16px を切ると密になりすぎるので省略する
        let beatSpacingPx = beatIntervalSec / viewport.secondsPerPixel(viewWidthPx: Double(drawableSize.width))
        if beatSpacingPx > 16 {
            drawLines(intervalSec: beatIntervalSec, widthPx: 1, color: beatGridColor)
        }
        drawLines(intervalSec: beatIntervalSec * Double(beatsPerBar), widthPx: 2, color: barGridColor)
    }

    // MARK: - 頂点構築（未生成の LOD を使うとき、または再構築の検証時）

    /// 時刻と振幅を持つ頂点を生成する。変換処理を Metal から分けて単体で検証できる。
    nonisolated static func makeVertexArray(level: WaveformLODLevel) -> [SIMD2<Float>] {
        WaveformVertexGeometry.makeVertices(level: level)
    }

    /// 頂点配列を CPU / GPU で共有する MTLBuffer へコピーする。
    /// 空でない LOD を渡す。配列の一時確保と makeBuffer のコピーは初回生成時に発生する。
    private func makeVertexBuffer(level: WaveformLODLevel) -> MTLBuffer? {
        let vertices = Self.makeVertexArray(level: level)
        return vertices.withUnsafeBufferPointer { buffer in
            device.makeBuffer(
                bytes: buffer.baseAddress!,
                length: buffer.count * MemoryLayout<SIMD2<Float>>.stride,
                options: .storageModeShared
            )
        }
    }

    /// analysis の代入時に全 LOD のバッファと入力時刻の履歴、集計途中の統計を破棄する。
    private func resetLevelCaches() {
        levelVertexBuffers = Array(repeating: nil, count: analysis?.levels.count ?? 0)
        playheadSampler = PlayheadSampler()
        resetStats(now: CACurrentMediaTime())
    }

    private func resetStats(now: CFTimeInterval) {
        statsWindowStart = now
        statsFrameCount = 0
        statsCPUTimeSum = 0
        statsRebuildCount = 0
        peakDriftPx = 0
    }

    // MARK: - 統計集計

    /// 約 0.5 秒の窓で描画回数と生成回数を秒あたりに換算し、CPU 時間を平均する。
    /// drift は窓内の最大値、LOD と頂点数は最後のフレームの値を通知する。
    private func accumulateStats(cpuStart: CFTimeInterval, level: WaveformLODLevel) {
        statsCPUTimeSum += CACurrentMediaTime() - cpuStart
        statsFrameCount += 1

        let elapsed = CACurrentMediaTime() - statsWindowStart
        guard elapsed >= Self.statsWindowSec else { return }

        let stats = RenderStats(
            fps: Double(statsFrameCount) / elapsed,
            cpuFrameMs: statsCPUTimeSum / Double(statsFrameCount) * 1000,
            rebuildsPerSecond: Double(statsRebuildCount) / elapsed,
            lodLevelIndex: lastLevelIndex,
            lodBucketMs: level.bucketDurationSec * 1000,
            drawnVertexCount: lastDrawnVertexCount,
            playheadDriftPx: peakDriftPx
        )
        resetStats(now: CACurrentMediaTime())
        onStats?(stats)
    }
}
