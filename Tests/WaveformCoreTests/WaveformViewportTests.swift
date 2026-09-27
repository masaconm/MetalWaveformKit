//
//  WaveformViewportTests.swift
//  WaveformCoreTests
//
//  CPU上での時刻と座標の対応、およびピクセル格子へ丸める補助APIを検証する。
//  純粋な値型を対象とするため、MainActorやMetalデバイスは不要。
//

import Testing
@testable import WaveformCore

/// ndcXはFloatで返るため、座標には1e-6〜1e-5、秒への往復には1e-4の許容差を置く。
/// Doubleだけで計算する秒数の比較には、より小さい1e-9を使う。
struct WaveformViewportTests {

    @Test("可視範囲の左端・中央・右端が NDC の -1 / 0 / +1 に写る")
    func projectionMapsVisibleRangeToNDC() {
        let viewport = WaveformViewport(visibleStartSec: 10, viewportSec: 4)
        #expect(abs(viewport.ndcX(forTimeSec: 10) - (-1)) < 1e-6)
        #expect(abs(viewport.ndcX(forTimeSec: 12) - 0) < 1e-6)
        #expect(abs(viewport.ndcX(forTimeSec: 14) - 1) < 1e-6)
    }

    @Test("中央固定カメラでは任意の再生位置・ズームでプレイヘッドが NDC 0 に写る")
    func centeredCameraKeepsPlayheadAtNDCZero() {
        // スナップ前のカメラで、中心に置いた時刻がNDC 0へ写ることを確かめる。
        // 実描画の中央固定線やスナップ後の画素位置はGPUテストが扱う。
        for playhead in [0.0, 13.37, 61.4, 479.9] {
            for viewportSec in [16.0, 4.0, 0.25] {
                let viewport = WaveformViewport.centered(onPlayheadSec: playhead, viewportSec: viewportSec)
                #expect(abs(viewport.ndcX(forTimeSec: playhead)) < 1e-5)
            }
        }
    }

    @Test("投影と逆投影が往復で一致する")
    func projectionRoundTrip() {
        let viewport = WaveformViewport(visibleStartSec: 42.5, viewportSec: 8)
        for time in stride(from: 42.5, through: 50.5, by: 0.5) {
            let ndc = Double(viewport.ndcX(forTimeSec: time))
            #expect(abs(viewport.timeSec(forNDCX: ndc) - time) < 1e-4)
        }
    }

    @Test("ビュー内の割合 0 / 0.5 / 1 が開始・中央・終了時刻に対応する")
    func viewFractionMapping() {
        let viewport = WaveformViewport(visibleStartSec: 100, viewportSec: 10)
        #expect(abs(viewport.timeSec(atViewFraction: 0) - 100) < 1e-9)
        #expect(abs(viewport.timeSec(atViewFraction: 0.5) - 105) < 1e-9)
        #expect(abs(viewport.timeSec(atViewFraction: 1) - 110) < 1e-9)
    }

    @Test("secondsPerPixel が viewport 幅 / ピクセル幅 になる")
    func secondsPerPixel() {
        let viewport = WaveformViewport(visibleStartSec: 0, viewportSec: 16)
        #expect(abs(viewport.secondsPerPixel(viewWidthPx: 1600) - 0.01) < 1e-9)
    }

    @Test("ピクセル格子スナップは開始位置を整数ピクセルへ量子化し、幅を変えない")
    func pixelGridSnappingQuantizesStartToWholePixels() {
        let raw = WaveformViewport(visibleStartSec: 12.3456789, viewportSec: 4)
        let snapped = raw.snappedToPixelGrid(drawableWidthPx: 1170)
        let pixelsPerSecond = 1170.0 / 4.0

        // 補助APIが返す開始時刻をピクセルへ換算し、整数に載ることを確認する。
        let startPx = snapped.visibleStartSec * pixelsPerSecond
        #expect(abs(startPx - startPx.rounded()) < 1e-6)
        // 丸めによる移動は最大 0.5px 以内
        #expect(abs(snapped.visibleStartSec - raw.visibleStartSec) <= 0.5 / pixelsPerSecond + 1e-9)
        // viewport 幅（= ズーム）は不変
        #expect(snapped.viewportSec == raw.viewportSec)
    }

    @Test("幅ゼロの viewport でも NaN を返さない")
    func degenerateViewportDoesNotProduceNaN() {
        // 幅ゼロの入力でもゼロ除算によるNaNや無限大を外へ返さない。
        let viewport = WaveformViewport(visibleStartSec: 0, viewportSec: 0)
        #expect(viewport.ndcX(forTimeSec: 1).isFinite)
    }
}
