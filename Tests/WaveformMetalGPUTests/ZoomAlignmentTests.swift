import Foundation
import Metal
import Testing
import WaveformCore
@testable import WaveformMetal

/// 実際のレンダラーを使い、ズーム・シーク・キュー変更後の画素位置を検証する。
/// 波形はバケット単位の包絡線なので、ピークには選択された LOD の時間幅を許容する。
@MainActor
struct ZoomAlignmentTests {
    // 同じ解析結果でLODを往復し、シークとキューの追加・削除を挟んでも位置関係が保たれるか調べる。
    @Test("GPU: waveform, playhead, cues and beats stay aligned through zoom and seek",
          arguments: [1206, 2732])
    func changingFrames(width: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let renderer = try #require(WaveformRenderer(device: device))
        let sampleRate = 48_000.0
        var samples = [Float](repeating: 0, count: Int(sampleRate * 432))
        // 既知の拍時刻に正負のインパルスを置く。シーク前後とも同じ解析結果を使う。
        for beat in 0..<900 {
            let index = Int((Double(beat) * 0.48 * sampleRate).rounded())
            samples[index] = -0.9
            samples[index + 1] = 0.9
        }
        renderer.analysis = WaveformAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
        renderer.beatIntervalSec = 0.48
        let surface = try Surface(device: device, width: width)
        let zooms: [Double] = [1, 1.3, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 48, 24, 8, 2, 1]
        var bucketDurations = Set<Double>()

        for (frame, zoom) in zooms.enumerated() {
            let beatTime = frame < 9 ? 420.0 : 84.0
            let playhead = beatTime + 0.09 + Double(frame) / 2_000
            let span = 16 / zoom
            // シェーダの計算式を複製せず、秒と画面幅から基準位置を求める。
            func expectedX(_ time: Double) -> Double {
                Double(width) * (0.5 + (time - playhead) / span)
            }
            let input = WaveformFrameInput(playheadSec: playhead, zoomScale: zoom)
            let (base, level) = try surface.render(renderer, input: input, queue: queue, frame: frame)
            bucketDurations.insert(level.bucketDurationSec)
            let beatX = expectedX(beatTime)

            // 波形のない上端で、拍線と再生線を独立に観測する。
            // 1.25pxには、カメラの丸めとMSAA・色しきい値による中心の測定差を含める。
            let grid = try #require(center(in: base, width: width, row: 3, near: beatX, radius: 4) {
                abs($0.r - $0.g) < 3 && abs($0.g - $0.b) < 3 && $0.r > 8
            })
            #expect(abs(grid - beatX) <= 1.25, "grid, frame \(frame), zoom \(zoom)")
            let head = try #require(center(in: base, width: width, row: 3,
                                          near: Double(width) / 2, radius: 4) {
                $0.r > $0.g * 2 && $0.b > $0.g
            })
            #expect(abs(head - Double(width) / 2) <= 1.25, "playhead, frame \(frame)")

            // min/max 集約による時刻の粗さと、画素の丸めを別の許容範囲にする。
            let bucketPixels = level.bucketDurationSec * Double(width) / span
            let wave = try #require(center(in: base, width: width, row: 20,
                                          near: beatX, radius: max(4, bucketPixels * 2)) {
                $0.g > $0.r + 30 && $0.b > $0.r + 20
            })
            #expect(abs(wave - beatX) <= bucketPixels + 1.25, "waveform, frame \(frame)")

            var withCues = input
            switch frame % 3 {
            case 1: withCues.cueTimesSec = [beatTime]
            // 広域表示でも線同士が重ならない位置に追加し、各線を独立に測る。
            case 2: withCues.cueTimesSec = [beatTime, beatTime + span * 0.2]
            default: withCues.cueTimesSec = []
            }
            let (marked, _) = try surface.render(renderer, input: withCues, queue: queue, frame: frame)
            for cue in withCues.cueTimesSec {
                let position = try #require(center(in: marked, width: width, row: 3,
                                                  near: expectedX(cue), radius: 4) {
                    $0.r > 100 && $0.g > $0.b * 1.8 && $0.g > $0.r * 0.4
                })
                #expect(abs(position - expectedX(cue)) <= 1.25, "cue, frame \(frame)")
            }
            if withCues.cueTimesSec.isEmpty {
                #expect(!pixels(in: marked, width: width, row: 3).contains {
                    $0.r > 100 && $0.g > $0.b * 1.8 && $0.g > $0.r * 0.4
                }, "removed cues must not remain in the next frame")
            }
        }
        #expect(bucketDurations.count >= 3, "the sequence must cross several LOD levels")
    }

    private struct Pixel {
        var r: Double
        var g: Double
        var b: Double
    }

    // BGRAテクスチャから読み取った1行を、色による線の識別に使うRGBへ並べ替える。
    private func pixels(in bytes: [UInt8], width: Int, row: Int) -> [Pixel] {
        (0..<width).map { x in
            let i = (row * width + x) * 4
            return Pixel(r: Double(bytes[i + 2]), g: Double(bytes[i + 1]), b: Double(bytes[i]))
        }
    }

    // 期待位置の近くで対象色を探し、両端の画素中心の中点を返す。離れた別の拍線を混ぜない。
    private func center(in bytes: [UInt8], width: Int, row: Int, near x: Double,
                        radius: Double, matches: (Pixel) -> Bool) -> Double? {
        let positions = pixels(in: bytes, width: width, row: row).enumerated().compactMap { i, pixel in
            abs(Double(i) + 0.5 - x) <= radius && matches(pixel) ? Double(i) + 0.5 : nil
        }
        guard let first = positions.first, let last = positions.last else { return nil }
        return (first + last) / 2
    }

    /// GPU専用のMSAAテクスチャへ描き、CPUで読める共有テクスチャに解決する。
    private struct Surface {
        let texture: MTLTexture
        let descriptor: MTLRenderPassDescriptor
        let width: Int
        let height = 64

        init(device: MTLDevice, width: Int) throws {
            self.width = width
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = .renderTarget
            desc.storageMode = .shared
            texture = try #require(device.makeTexture(descriptor: desc))
            desc.textureType = .type2DMultisample
            desc.sampleCount = 4
            desc.storageMode = .private
            let multisample = try #require(device.makeTexture(descriptor: desc))
            descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = multisample
            descriptor.colorAttachments[0].resolveTexture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .multisampleResolve
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        }

        @MainActor
        func render(_ renderer: WaveformRenderer, input: WaveformFrameInput,
                    queue: MTLCommandQueue, frame: Int) throws -> ([UInt8], WaveformLODLevel) {
            let command = try #require(queue.makeCommandBuffer())
            let level = try #require(renderer.encodeFrame(
                input: input, into: command, descriptor: descriptor,
                size: CGSize(width: width, height: height), atTime: Double(frame) / 120))
            command.commit()
            // CPU側の投影計算だけで合格にせず、GPUが実際に書いた画素を完了後に読む。
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return (bytes, level)
        }
    }
}
