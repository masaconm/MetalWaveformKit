import Foundation
import Metal
import Testing
import WaveformCore
@testable import WaveformMetal

/// 実際の描画画素で、中央の再生線と時間軸上の波形・キューを別々に検証する。
@MainActor
struct PlayheadScreenSpaceTests {
    // 奇数幅と偶数幅の両方で、ズーム・スナップ・小数pxの入力にかかわらず同じ画素帯に固定する。
    @Test("GPU: synced playhead pixels stay centered through camera phases and zoom",
          arguments: [1083, 1576])
    func stableCenter(width: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(WaveformRenderer(device: device))
        // 長い時刻でも上端には波形がない入力を作り、再生線の画素だけを測る。
        renderer.analysis = WaveformAnalyzer.analyze(
            samples: (0..<48_000).map { $0.isMultiple(of: 2) ? Float(-0.25) : Float(0.25) },
            sampleRate: 100
        )
        renderer.beatIntervalSec = 0
        let surface = try Surface(device: device, width: width)
        var reference: [UInt8]?
        var frame = 0
        for snap in [true, false] {
            for zoom in [1.0, 4, 16, 64] {
                let pixelsPerSecond = Double(width) * zoom / 16
                for offset in [0.0, 0.1, 0.25, 0.49, 0.5, 0.75, 0.99, 1.25, 8.25] {
                    let input = WaveformFrameInput(
                        playheadSec: 420.123 + offset / pixelsPerSecond,
                        zoomScale: zoom, unsnappedCamera: !snap
                    )
                    let bytes = try surface.render(renderer, input: input, now: Double(frame) / 120)
                    let row = surface.row(bytes, y: 3)
                    if let reference {
                        #expect(row == reference, "snap \(snap), zoom \(zoom), offset \(offset)")
                    } else {
                        reference = row
                        let center = try #require(surface.redCenter(bytes))
                        // 線を覆う画素の中心と、連続座標上の中央との差として半画素まで許容する。
                        #expect(abs(center - Double(width) / 2) <= 0.5)
                    }
                    frame += 1
                }
            }
        }
    }

    // 時間軸と一緒に動く波形・キュー・拍線を、画面中央に固定された再生線から分けて測る。
    @Test("GPU: snapped waveform and cue pixels retain their shared translation",
          arguments: [1083, 1576])
    func waveformAndCues(width: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(WaveformRenderer(device: device))
        let rate = 48_000.0
        let samples = (0..<96_000).map { index -> Float in
            let time = Double(index) / rate
            let phase = time.truncatingRemainder(dividingBy: 0.5)
            return Float(sin(time * 2 * .pi * 110) * exp(-phase * 22) * 0.8)
        }
        renderer.analysis = WaveformAnalyzer.analyze(samples: samples, sampleRate: rate)
        renderer.beatIntervalSec = 0.5
        let surface = try Surface(device: device, width: width)
        let zoom = 64.0
        let span = 16 / zoom
        let pixelsPerSecond = Double(width) / span
        let baseCamera = ((1 - span / 2) * pixelsPerSecond).rounded()
        let time = baseCamera / pixelsPerSecond + span / 2
        let cue = time + span * 0.25
        func input(_ offset: Double) -> WaveformFrameInput {
            WaveformFrameInput(playheadSec: time + offset / pixelsPerSecond,
                               zoomScale: zoom, cueTimesSec: [cue])
        }
        let baseline = try surface.render(renderer, input: input(0), now: 0)
        let quarter = try surface.render(renderer, input: input(0.25), now: 1.0 / 120)
        // 1/4pxの入力ではカメラが同じ整数に留まり、再生線も含め全画素が一致する。
        #expect(quarter == baseline)
        let translated = try surface.render(renderer, input: input(1), now: 2.0 / 120)
        var changed = 0
        var count = 0
        let center = width / 2
        for y in 0..<surface.height {
            for x in 2..<(width - 3) where abs(x - center) > 6 {
                let a = (y * width + x + 1) * 4
                let b = (y * width + x) * 4
                if baseline[a..<(a + 4)] != translated[b..<(b + 4)] { changed += 1 }
                count += 1
            }
        }
        // 固定された再生線を除き、波形・キュー・グリッドは同じ1px平行移動を保つ。
        // NDCから画素への境界判定による少数の差は既存CameraRasterTestsと同じ許容率。
        #expect(Double(changed) / Double(count) < 0.0001)
        let baselineCue = try #require(surface.orangeCenter(baseline))
        let movedCue = try #require(surface.orangeCenter(translated))
        // MSAAと色しきい値で求める中心には0.25pxを許容し、1px移動とのずれを調べる。
        #expect(abs(movedCue - (baselineCue - 1)) <= 0.25)
        // 再生線の隣を拍線が通過するので、ここでは背景を含む帯ではなく線の中心を測る。
        #expect(surface.redCenter(baseline) == surface.redCenter(translated))
    }

    // 遅延モードでは時刻差が12pxのずれとして現れ、通常モードへ戻すと中央へ復帰する。
    @Test("GPU: delayed playhead modes keep their clock offset and return to center",
          arguments: [PlayheadProjectionMode.oneFrameStale, .throttled20Hz])
    func delayedModes(mode: PlayheadProjectionMode) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(WaveformRenderer(device: device))
        renderer.analysis = WaveformAnalyzer.analyze(
            samples: [Float](repeating: 0, count: 48_000), sampleRate: 100
        )
        renderer.beatIntervalSec = 0
        let width = 1083
        let surface = try Surface(device: device, width: width)
        let zoom = 64.0
        let pixelsPerSecond = Double(width) * zoom / 16
        let start = 420.123456
        func input(_ time: Double, _ mode: PlayheadProjectionMode) -> WaveformFrameInput {
            WaveformFrameInput(playheadSec: time, zoomScale: zoom, playheadProjection: mode)
        }
        let initial = try surface.render(renderer, input: input(start, mode), now: 0)
        let delayed = try surface.render(renderer, input: input(start + 12 / pixelsPerSecond, mode), now: 0.01)
        let initialCenter = try #require(surface.redCenter(initial))
        let delayedCenter = try #require(surface.redCenter(delayed))
        #expect(abs(initialCenter - Double(width) / 2) <= 0.5)
        #expect(abs(delayedCenter - (Double(width) / 2 - 12)) <= 0.5)
        // モードを戻した最初のフレームから、遅延を持ち越さず同じ画素帯へ戻る。
        let synced = try surface.render(renderer, input: input(start + 20 / pixelsPerSecond, .synced), now: 0.02)
        #expect(surface.row(initial, y: 3) == surface.row(synced, y: 3))
    }

    /// 表示ウィンドウを使わず、4サンプルのMSAA結果を読み戻すテスト用描画先。
    private struct Surface {
        let width: Int
        let height = 96
        let queue: MTLCommandQueue
        let texture: MTLTexture
        let descriptor: MTLRenderPassDescriptor

        init(device: MTLDevice, width: Int) throws {
            self.width = width
            queue = try #require(device.makeCommandQueue())
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            textureDescriptor.usage = .renderTarget
            textureDescriptor.storageMode = .shared
            texture = try #require(device.makeTexture(descriptor: textureDescriptor))
            textureDescriptor.textureType = .type2DMultisample
            textureDescriptor.sampleCount = 4
            textureDescriptor.storageMode = .private
            let multisample = try #require(device.makeTexture(descriptor: textureDescriptor))
            descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = multisample
            descriptor.colorAttachments[0].resolveTexture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .multisampleResolve
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        }

        @MainActor
        func render(_ renderer: WaveformRenderer, input: WaveformFrameInput, now: Double) throws -> [UInt8] {
            let command = try #require(queue.makeCommandBuffer())
            _ = try #require(renderer.encodeFrame(
                input: input, into: command, descriptor: descriptor,
                size: CGSize(width: width, height: height), atTime: now
            ))
            command.commit()
            // 未完了のテクスチャを読まないよう、テストではGPUの完了を同期的に待つ。
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }

        func row(_ bytes: [UInt8], y: Int) -> [UInt8] {
            Array(bytes[(y * width * 4)..<((y + 1) * width * 4)])
        }

        func redCenter(_ bytes: [UInt8]) -> Double? {
            center(bytes) { r, g, b in r > g * 2 && r > b * 1.5 }
        }

        func orangeCenter(_ bytes: [UInt8]) -> Double? {
            center(bytes) { r, g, b in r > 100 && g > b * 1.8 && g > r * 0.4 }
        }

        // 波形のない上端をBGRAとして読み、対象色の最初と最後の画素中心から線の中心を求める。
        private func center(_ bytes: [UInt8], matches: (Double, Double, Double) -> Bool) -> Double? {
            let positions = (0..<width).filter { x in
                let i = (3 * width + x) * 4
                return matches(Double(bytes[i + 2]), Double(bytes[i + 1]), Double(bytes[i]))
            }
            guard let first = positions.first, let last = positions.last else { return nil }
            return (Double(first + last) + 1) / 2
        }
    }
}
