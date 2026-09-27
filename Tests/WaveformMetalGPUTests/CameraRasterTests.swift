import Foundation
import Metal
import Testing
import WaveformCore
@testable import WaveformMetal

/// 実際の描画用シェーダーでテクスチャに描き、CPU の計算に加えてピクセルの描画範囲を検証する。
struct CameraRasterTests {
    // スナップONでは0.25pxの入力差で画素を変えず、1pxの入力差では平行移動させる。
    // OFFでは画素の明るさが変わることも確認し、スナップが無効な実装を検出する。
    @Test("GPU: snap ON holds coverage, OFF changes subpixel coverage", arguments: [1.0, 4, 16, 64], [1206, 2732])
    func coverage(zoom: Double, width: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WaveformMetal/Shaders.metal")
        let shader = try String(contentsOf: path, encoding: .utf8)
        let library = try device.makeLibrary(source: shader, options: nil)
        let pipelineDescription = MTLRenderPipelineDescriptor()
        pipelineDescription.vertexFunction = library.makeFunction(name: "waveform_vertex")
        pipelineDescription.fragmentFunction = library.makeFunction(name: "flat_fragment")
        pipelineDescription.colorAttachments[0].pixelFormat = .rgba8Unorm
        pipelineDescription.rasterSampleCount = 4
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescription)
        // 同じシェーダーの投影式だけを旧式へ戻し、長い時刻の減算による精度低下を再現する。
        let legacyShader = shader.replacingOccurrences(
            of: "fma(timeSec, viewport.pixelsPerSecond, -viewport.cameraStartPx) - viewport.cameraFractionPx",
            with: "(timeSec - ((viewport.cameraStartPx + viewport.cameraFractionPx) / viewport.pixelsPerSecond)) * viewport.pixelsPerSecond")
        let legacyLibrary = try device.makeLibrary(source: legacyShader, options: nil)
        pipelineDescription.vertexFunction = legacyLibrary.makeFunction(name: "waveform_vertex")
        let legacyPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescription)
        let queue = try #require(device.makeCommandQueue())
        let height = 64
        let viewportSec = 16 / zoom
        let pixelsPerSecond = Double(width) / viewportSec
        let basePixel = (420 * pixelsPerSecond).rounded()
        // 急なエッジを意図的に繰り返し、サブピクセル単位の描画範囲の変化を測定可能にする。
        var vertices: [SIMD2<Float>] = []
        for i in -32...1100 {
            let time = Float((basePixel + Double(i) * 1.02) / pixelsPerSecond)
            let amplitude: Float = i.isMultiple(of: 3) ? 0.9 : 0.1
            vertices += [SIMD2(time, -amplitude), SIMD2(time, amplitude)]
        }
        let buffer = try #require(device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride))
        func render(offset: Double, snap: Bool, legacy: Bool = false) throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            // 4サンプルのMSAAで描き、CPUで読める共有テクスチャへ解決する。
            descriptor.storageMode = .shared
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = 4
            descriptor.storageMode = .private
            let msaa = try #require(device.makeTexture(descriptor: descriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = msaa
            pass.colorAttachments[0].resolveTexture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .multisampleResolve
            let command = try #require(queue.makeCommandBuffer())
            let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
            var uniforms = ViewportUniforms(
                viewport: WaveformViewport(visibleStartSec: (basePixel + offset) / pixelsPerSecond, viewportSec: viewportSec),
                drawableWidthPx: Double(width), snap: snap, amplitudeScale: 1)
            var color = SIMD4<Float>(1, 1, 1, 1)
            encoder.setRenderPipelineState(legacy ? legacyPipeline : pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 1)
            encoder.setVertexBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()
            command.commit()
            // 画素の読み戻しはGPU完了後に行う。この同期待ちはテスト専用。
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }
        let snapped = try render(offset: 0, snap: true)
        #expect(snapped == (try render(offset: 0.25, snap: true)))
        let moving = try render(offset: 0.25, snap: false)
        let changed = zip(snapped, moving).filter { $0 != $1 }.count
        // 単発の境界ピクセル差と区別するため、複数のエッジに広がる変化を要求する。
        #expect(changed > 100)
        let translated = try render(offset: 1, snap: true)
        var mismatches = 0
        for y in 0..<height {
            for x in 2..<(width - 2) {
                if snapped[(y * width + x + 1) * 4] != translated[(y * width + x) * 4] { mismatches += 1 }
            }
        }
        // 幅が 2 の累乗でない場合、境界ピクセルの判定で数ピクセルの差が出ることがある。
        // 差は 0.01% 未満を許容する。カメラの位相誤差なら数百〜数千ピクセルに影響する。
        #expect(Double(mismatches) / Double(width * height) < 0.0001)
        // 旧式との差が実際に現れる入力であることも確認し、回帰を検出できる比較条件を保つ。
        let legacyA = try render(offset: 0, snap: true, legacy: true)
        let legacyB = try render(offset: 1, snap: true, legacy: true)
        var legacyMismatches = 0
        for y in 0..<height {
            for x in 2..<(width - 2) {
                if legacyA[(y * width + x + 1) * 4] != legacyB[(y * width + x) * 4] { legacyMismatches += 1 }
            }
        }
        #expect(legacyMismatches > mismatches)
        print("Legacy translation mismatches=\(legacyMismatches), width=\(width), zoom=\(zoom)")
        print("GPU width=\(width), zoom=\(zoom): subpixel changed bytes=\(changed), snapped translation mismatches=\(mismatches)")
    }
}
