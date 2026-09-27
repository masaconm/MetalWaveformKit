import Foundation
import Testing
import WaveformCore
@testable import WaveformMetal

/// 再生線の遅延再現モードと、GPUへ渡すカメラ座標の数値的な性質をCPU上で確認する。
struct ProjectionBehaviorTests {
    // 異なるモードへ切り替えた直後は、前のモードの古い時刻を引き継がない。
    @Test("All mode transitions start from the current clock", arguments: PlayheadProjectionMode.allCases, PlayheadProjectionMode.allCases)
    func transitions(from: PlayheadProjectionMode, to: PlayheadProjectionMode) {
        var sampler = PlayheadSampler()
        #expect(sampler.sample(playheadSec: 120, mode: from, now: 0) == 120)
        let value = sampler.sample(playheadSec: 121, mode: to, now: 0.01)
        if from != to || to == .synced { #expect(value == 121) }
    }

    // シークのように時刻が飛んでも、ちょうど一つ前の入力を返すことを確かめる。
    @Test("Stale mode uses exactly the preceding frame, including seeks")
    func stale() {
        var sampler = PlayheadSampler()
        for (i, time) in [120.0, 120.01, 400, 400.01].enumerated() {
            let value = sampler.sample(playheadSec: time, mode: .oneFrameStale, now: Double(i) / 120)
            #expect(value == [120.0, 120, 120.01, 400][i])
        }
    }

    // 60/120 Hzのフレーム入力に対し、50 msごとの値を保持する。1e-9秒はDouble演算の許容差。
    @Test("20Hz holds for 50ms at both display rates", arguments: [60.0, 120.0])
    func throttled(fps: Double) {
        var sampler = PlayheadSampler()
        for frame in 0...Int(fps) {
            let time = Double(frame) / fps
            let sampled = sampler.sample(playheadSec: 120 + time, mode: .throttled20Hz, now: time)
            let expected = 120 + Double(frame / Int(fps / 20)) / 20
            #expect(abs(sampled - expected) < 1e-9)
        }
    }

    // 420秒付近でも整数pxの移動で波形の位相が変わらないことを、各倍率・幅で確認する。
    // 1e-4pxの許容差はFloat演算向け。実際のラスタライズ結果はGPUテストで別に測る。
    @Test("Snapping remains in whole pixels at long times and every zoom", arguments: [1.0, 4, 16, 64], [750.0, 1206, 2048, 2732])
    func snapPrecision(zoom: Double, width: Double) {
        let viewportSec = 16 / zoom
        let scale = Float(width) / Float(viewportSec)
        let time: Float = 420.123
        var phase: Double?
        for step in 0..<100 {
            let pixel = (420 * Double(scale)).rounded() + Double(step)
            let viewport = WaveformViewport(visibleStartSec: pixel / Double(scale), viewportSec: viewportSec)
            let uniforms = ViewportUniforms(viewport: viewport, drawableWidthPx: width, snap: true, amplitudeScale: 1)
            #expect(uniforms.cameraStartPx == uniforms.cameraStartPx.rounded())
            // Metal の fma と同様に、乗算と加算を終えた後に一度だけ丸める。
            let x = (-uniforms.cameraStartPx).addingProduct(time, uniforms.pixelsPerSecond)
            let shifted = Double(x) + Double(uniforms.cameraStartPx)
            if let phase { #expect(abs(shifted - phase) < 0.0001) }
            else { phase = shifted }
        }
    }
}
