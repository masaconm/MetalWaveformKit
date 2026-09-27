//
//  WaveformRenderResources.swift
//  WaveformMetal
//
//  描画開始前に一度だけ用意する Metal オブジェクト。
//  シェーダの読み込みとパイプライン設定を、毎フレームの描画から分離する。
//

import Metal

@MainActor
struct WaveformRenderResources {
    let commandQueue: MTLCommandQueue
    let waveformPipeline: MTLRenderPipelineState
    let markerPipeline: MTLRenderPipelineState

    /// コマンドキューと 2 種類のパイプラインを用意する。
    /// リソースの読み込みや生成に失敗した場合は nil を返し、利用側で表示を切り替える。
    init?(device: MTLDevice, rasterSampleCount: Int) {
        guard
            let commandQueue = device.makeCommandQueue(),
            // SwiftPM のシェーダはアプリ本体ではなく Bundle.module に格納される。
            let library = try? device.makeDefaultLibrary(bundle: .module),
            let waveformVertex = library.makeFunction(name: "waveform_vertex"),
            let markerVertex = library.makeFunction(name: "marker_vertex"),
            let fragment = library.makeFunction(name: "flat_fragment"),
            let waveformPipeline = Self.makePipeline(
                device: device,
                vertex: waveformVertex,
                fragment: fragment,
                rasterSampleCount: rasterSampleCount
            ),
            let markerPipeline = Self.makePipeline(
                device: device,
                vertex: markerVertex,
                fragment: fragment,
                rasterSampleCount: rasterSampleCount
            )
        else {
            return nil
        }

        self.commandQueue = commandQueue
        self.waveformPipeline = waveformPipeline
        self.markerPipeline = markerPipeline
    }

    private static func makePipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction,
        rasterSampleCount: Int
    ) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        // 描画先の sampleCount と一致させる。不一致の描画は Metal の検証エラーになる。
        descriptor.rasterSampleCount = rasterSampleCount
        let attachment = descriptor.colorAttachments[0]!
        // 描画先も bgra8Unorm に設定する。
        attachment.pixelFormat = .bgra8Unorm
        // マーカーの半透明色のためアルファブレンドを有効化する。
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
}
