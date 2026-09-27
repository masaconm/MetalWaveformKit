import Metal
import SwiftUI
import MetalWaveformKit

/// Metal が使える場合に、固定の表示時刻を返す最小構成のレンダラーを作る。
/// View が保持するため、SwiftUI の再評価ごとにパイプラインを作り直す必要はない。
@MainActor
func makeWaveformRenderer(analysis: WaveformAnalysis) -> WaveformRenderer? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let renderer = WaveformRenderer(device: device) else { return nil }
    renderer.analysis = analysis
    renderer.frameInputProvider = {
        WaveformFrameInput(playheadSec: 0.5, zoomScale: 16)
    }
    return renderer
}

/// 1秒分の合成波形を静止表示する、導入手順用の最小ビュー。
struct QuickStartView: View {
    @State private var renderer: WaveformRenderer?
    @State private var failed = false

    var body: some View {
        Group {
            if let renderer {
                WaveformMetalView(renderer: renderer)
                    .frame(height: 240)
            } else if failed {
                Text("Metal rendering is unavailable.")
            } else {
                ProgressView("Preparing waveform…")
            }
        }
        .task {
            guard renderer == nil, !failed else { return }
            // 解析はメインActorの外で行い、不変の結果を受け取る。
            let analysis = await Task.detached {
                let rate = 48_000.0
                let samples = (0..<48_000).map { i in
                    Float(sin(Double(i) / rate * 2 * .pi * 5) * 0.8)
                }
                return WaveformAnalyzer.analyze(samples: samples, sampleRate: rate)
            }.value
            // detached の解析が終わるまでに画面が閉じられた場合は、GPUリソースを作らない。
            guard !Task.isCancelled else { return }
            renderer = makeWaveformRenderer(analysis: analysis)
            failed = renderer == nil
        }
    }
}
