//
//  WaveformRenderModels.swift
//  WaveformMetal
//
//  利用側とレンダラーの間で渡す入力、検証モード、描画統計を定義する。
//

// MARK: - デモ用: プレイヘッド投影モード

/// 再生線の位置に用いる入力時刻の取得方法。
/// 古い入力を使った場合のずれを検証できる。通常の表示には `synced` を使う。
public nonisolated enum PlayheadProjectionMode: String, CaseIterable, Identifiable, Sendable {
    /// 現在の入力時刻を使い、再生線を画面中央へ固定する。
    /// 入力時刻同士の差を測る drift は 0 になる。波形の描画誤差を示す値ではない。
    case synced
    /// 前回の描画入力を使い、現在時刻との差を再生線の変位として表示する。
    case oneFrameStale
    /// 約 0.05 秒ごとに取得する再生位置を使い、低頻度の入力による追従遅延を再現する。
    case throttled20Hz

    /// UI の選択肢などで使う、モード名に基づく識別子。
    public nonisolated var id: String { rawValue }
}

// MARK: - フレーム入力と統計

/// 1 フレーム内で共有する描画入力。
/// 再生状態は利用側が管理し、レンダラーは入力 provider から一度だけ取得する。
/// 時刻と倍率には有限値を渡す。音声の再生、シーク、拍への整列は行わない。
public nonisolated struct WaveformFrameInput {

    /// 描画入力を作る。既定値は 0 秒、1 倍表示、キューなし、ピクセルスナップ有効。
    public init(
        playheadSec: Double = 0,
        zoomScale: Double = 1,
        cueTimesSec: [Double] = [],
        rebuildEveryFrame: Bool = false,
        playheadProjection: PlayheadProjectionMode = .synced,
        unsnappedCamera: Bool = false
    ) {
        self.playheadSec = playheadSec
        self.zoomScale = zoomScale
        self.cueTimesSec = cueTimesSec
        self.rebuildEveryFrame = rebuildEveryFrame
        self.playheadProjection = playheadProjection
        self.unsnappedCamera = unsnappedCamera
    }

    /// 表示の中心とするトラック時刻（秒）。トラック範囲外でも描画できる。
    public var playheadSec: Double = 0
    /// 拡大率。正の値を渡す。1 倍の表示幅は `WaveformRenderer.viewportSecondsAtZoom1`。
    public var zoomScale: Double = 1
    /// キューマーカーを描くトラック時刻（秒）。件数の制限や拍への整列は利用側で行う。
    public var cueTimesSec: [Double] = []
    /// 検証用。最細 LOD のバッファを毎フレーム作り直し、追加の CPU 負荷を発生させる。
    public var rebuildEveryFrame = false
    /// 通常は `synced`。別のモードでは古い入力時刻によるずれを再現する。
    public var playheadProjection: PlayheadProjectionMode = .synced
    /// true ならカメラのピクセルスナップを無効にする。再生線の中央固定は変わらない。
    public var unsnappedCamera = false
}

/// HUD などへ渡す描画統計。レンダラーは約 0.5 秒の窓で集計して通知する。
/// LOD と頂点数は窓の最後のフレームの値。GPU 完了時刻や音声出力の遅延は測定しない。
public nonisolated struct RenderStats: Equatable, Sendable {
    /// コマンドを送信できた描画回数 / 集計窓の秒数。画面の実表示回数ではない。
    public var fps: Double = 0
    /// 入力取得からコマンドの commit までの CPU 側の平均経過時間（ms）。
    /// GPU 完了は待たず、統計コールバックの実行時間も含めない
    public var cpuFrameMs: Double = 0
    /// LOD バッファの生成試行回数 / 集計窓の秒数。初回や解析結果の変更後も計上する。
    public var rebuildsPerSecond: Double = 0
    /// 最後に選択した LOD の番号。0 が最も細かい。
    public var lodLevelIndex: Int = 0
    /// 選択した LOD の 1 バケットが表す時間幅（ms）。
    public var lodBucketMs: Double = 0
    /// 最後に波形の draw 命令へ指定した頂点数。グリッドやマーカーは含まない。
    public var drawnVertexCount: Int = 0
    /// 現在と取得済みの再生時刻を CPU で投影した差の、集計窓内の最大値（drawable px）。
    /// ピクセルスナップの効果、ラスタライズの誤差、音声との同期誤差を表す値ではない。
    public var playheadDriftPx: Double = 0

    /// 最初の統計通知までの初期表示に使える、全項目が 0 の値。
    public static let zero = RenderStats()
}
