import MetalKit
import QuartzCore
import Testing
import WaveformMetal

/// 描画先がまだなくても、公開描画入口での時計の受け渡しと旧 API の互換性を確かめる。
@MainActor
struct FrameInputTimingTests {
    // 表示予定のホスト時刻を一度だけ渡し、時刻付きプロバイダー未設定時は旧APIを使う。
    @Test("Presentation host time is forwarded once and takes priority over the legacy provider")
    func timedProviderAndLegacyFallback() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(WaveformRenderer(device: device))
        // drawableを持たない停止ビューで、描画の成否と独立に入力の取得だけを検証する。
        let view = MTKView(frame: .zero, device: device)
        view.isPaused = true
        var legacyCalls = 0
        var receivedTimes: [CFTimeInterval] = []
        renderer.frameInputProvider = {
            legacyCalls += 1
            return WaveformFrameInput(playheadSec: 12)
        }
        renderer.timedFrameInputProvider = { hostTime in
            receivedTimes.append(hostTime)
            return WaveformFrameInput(playheadSec: 24)
        }
        let target = CACurrentMediaTime() + 1.0 / 60
        renderer.draw(in: view, atHostTime: target)
        #expect(receivedTimes == [target])
        #expect(legacyCalls == 0)

        renderer.timedFrameInputProvider = nil
        renderer.draw(in: view, atHostTime: target + 1.0 / 60)
        #expect(receivedTimes == [target])
        #expect(legacyCalls == 1)
    }

    // 時刻指定なし・NaN・無限大の入力では、呼び出し前後のホスト時刻の範囲へ戻す。
    @Test("Delegate entry and invalid target times fall back to the current host clock")
    func currentClockFallback() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(WaveformRenderer(device: device))
        let view = MTKView(frame: .zero, device: device)
        view.isPaused = true
        var receivedTimes: [CFTimeInterval] = []
        renderer.timedFrameInputProvider = { hostTime in
            receivedTimes.append(hostTime)
            return WaveformFrameInput()
        }
        // 実時間の進み方に依存するため固定の許容差を置かず、前後の時刻で範囲を作る。
        let before = CACurrentMediaTime()
        renderer.draw(in: view)
        renderer.draw(in: view, atHostTime: .nan)
        renderer.draw(in: view, atHostTime: .infinity)
        let after = CACurrentMediaTime()
        #expect(receivedTimes.count == 3)
        #expect(receivedTimes.allSatisfy { $0 >= before && $0 <= after })
    }
}
