//
//  PixelSnapComparisonView.swift
//  RenderingDemo
//
//  責務: 同じ波形・同じカメラ入力を実際のMetal描画で比較する
//

import MetalKit
import Observation
import SwiftUI
import MetalWaveformKit

/// 通常画面と独立した表示位置を、スナップON/OFFの2台へ渡す。
/// MTKView の delegate は弱参照なので、比較中のレンダラーはここで保持する。
@MainActor
@Observable
private final class PixelSnapComparisonModel {
    // 描画解像度を固定し、端末の画面密度やウィンドウサイズで比較条件が変わるのを防ぐ。
    static let drawableSize = CGSize(width: 96, height: 48)
    static let magnification = 24.0
    static let detailRect = CGRect(x: 53, y: 11, width: 20, height: 24)
    static let zoom = 64.0
    static let startTime = 32.0
    // シェーダーと同じ Float の倍率から、指定したピクセル移動を表示秒へ換算する。
    static let pixelsPerSecond = Double(Float(drawableSize.width) / Float(16 / zoom))

    private(set) var offsetPx = 0.0
    private(set) var isPlaying = false
    let snappedRenderer: WaveformRenderer?
    let unsnappedRenderer: WaveformRenderer?
    let error: String?

    var time: Double { Self.startTime + offsetPx / Self.pixelsPerSecond }
    var snappedOffsetPx: Double { offsetPx.rounded() }

    init(analysis: WaveformAnalysis) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let snapped = WaveformRenderer(device: device),
              let unsnapped = WaveformRenderer(device: device) else {
            snappedRenderer = nil
            unsnappedRenderer = nil
            error = "Metal rendering is unavailable."
            return
        }
        snappedRenderer = snapped
        unsnappedRenderer = unsnapped
        error = nil
        // 通常画面と同じ解析結果・描画経路を使い、カメラの丸めだけを変える。
        for renderer in [snapped, unsnapped] {
            renderer.analysis = analysis
            renderer.beatIntervalSec = 0.5
        }
        snapped.frameInputProvider = { [weak self] in
            WaveformFrameInput(playheadSec: self?.time ?? Self.startTime, zoomScale: Self.zoom)
        }
        unsnapped.frameInputProvider = { [weak self] in
            WaveformFrameInput(
                playheadSec: self?.time ?? Self.startTime,
                zoomScale: Self.zoom,
                unsnappedCamera: true
            )
        }
    }

    func play() { offsetPx = 0; isPlaying = true }
    func pause() { isPlaying = false }
    func toggleMotion() { isPlaying ? pause() : play() }
    // 自動再生は0と0.25pxの往復。Stepでは0.5pxの丸め境界も確認できる。
    func advanceMotion() { offsetPx = offsetPx == 0 ? 0.25 : 0 }
    func step() { pause(); offsetPx = min(1, offsetPx + 0.25) }
    func reset() { pause(); offsetPx = 0 }
}

/// 実描画の同じ部分を24倍で表示し、小さな往復で画素の明るさの変化を確認する。
struct PixelSnapComparisonView: View {
    let analysis: WaveformAnalysis
    @Binding var language: ExplanationLanguage
    @State private var model: PixelSnapComparisonModel?

    var body: some View {
        Group {
            if let model {
                PixelSnapComparisonContentView(model: model, language: $language)
            } else {
                ProgressView("Preparing comparison…")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Viewの値が再生成されても、表示中のMetalパイプラインは一度だけ作る。
            guard model == nil, !Task.isCancelled else { return }
            model = PixelSnapComparisonModel(analysis: analysis)
        }
    }
}

private struct PixelSnapComparisonContentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let model: PixelSnapComparisonModel
    @Binding var language: ExplanationLanguage

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: language.text("Watch the cyan edges. The comparison alternates between 0 and 0.25 pixels: ON stays still; OFF changes brightness."))
                        .accessibilityIdentifier("explanation-compare-intro")
                        .font(.subheadline)
                    if let snapped = model.snappedRenderer,
                       let unsnapped = model.unsnappedRenderer {
                        Text("Camera input: \(model.offsetPx, specifier: "%.2f") px")
                            .font(.headline.monospacedDigit())
                            .accessibilityIdentifier("snap-compare-offset")
                        comparisonPanels(snapped: snapped, unsnapped: unsnapped)
                        controls
                        Text(verbatim: language.text("The same detail of actual Metal rendering is enlarged 24× without smoothing. Each source pixel covers 24 × 24 screen pixels."))
                        .accessibilityIdentifier("explanation-compare-detail")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(verbatim: language.text("Step pauses the comparison. At 0.50 px, ON moves by one whole pixel. Reset returns to 0. Inspection does not change the main controls."))
                        .accessibilityIdentifier("explanation-compare-controls")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.error ?? "Metal rendering is unavailable.")
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .background(Color(red: 0.09, green: 0.10, blue: 0.13).ignoresSafeArea())
            .navigationTitle("Inspect pixels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ExplanationLanguageMenu(language: $language)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("snap-compare-close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // 「視差効果を減らす」の設定時は、明滅を伴う比較を自動開始しない。
            if !reduceMotion { model.play() }
        }
        .task(id: model.isPlaying) {
            // 同じ入力を0と0.25pxで往復させ、ONの固定とOFFの明滅を見比べる。
            while model.isPlaying && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
                guard model.isPlaying && !Task.isCancelled else { return }
                model.advanceMotion()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { model.pause() }
        }
        .onChange(of: reduceMotion) {
            if reduceMotion { model.pause() }
        }
        .onDisappear { model.pause() }
    }

    private func comparisonPanels(
        snapped: WaveformRenderer, unsnapped: WaveformRenderer
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 12) {
                    comparisonPanel(title: "Snap ON", renderer: snapped,
                                    cameraOffset: model.snappedOffsetPx, identifier: "snap-compare-on")
                    comparisonPanel(title: "Snap OFF", renderer: unsnapped,
                                    cameraOffset: model.offsetPx, identifier: "snap-compare-off")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 16) {
                comparisonPanel(title: "Snap ON", renderer: snapped,
                                cameraOffset: model.snappedOffsetPx, identifier: "snap-compare-on")
                comparisonPanel(title: "Snap OFF", renderer: unsnapped,
                                cameraOffset: model.offsetPx, identifier: "snap-compare-off")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func comparisonPanel(
        title: String, renderer: WaveformRenderer,
        cameraOffset: Double, identifier: String
    ) -> some View {
        // ポイントへ換算し、元の1pxが端末上の24×24pxとして表示される寸法にする。
        let scale = max(displayScale, 1)
        let crop = PixelSnapComparisonModel.detailRect
        let magnification = PixelSnapComparisonModel.magnification
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text("Camera: \(cameraOffset, specifier: "%.2f") px")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            PixelSnapMetalView(
                renderer: renderer, offsetPx: model.offsetPx, displayScale: scale,
                identifier: identifier, title: title
            )
            .frame(width: crop.width * magnification / scale,
                   height: crop.height * magnification / scale)
            .overlay(Rectangle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Button(action: model.toggleMotion) {
                Label(model.isPlaying ? "Pause comparison" : "Play comparison",
                      systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(HardwareButtonStyle(foregroundColor: .teal))
            .accessibilityIdentifier("snap-compare-play")
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Button(action: model.step) {
                    Label("Step 0.25 px", systemImage: "arrow.right")
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(HardwareButtonStyle(foregroundColor: .teal))
                .disabled(model.offsetPx >= 1)
                .accessibilityIdentifier("snap-compare-step")
                Button(action: model.reset) {
                    Text("Reset")
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(HardwareButtonStyle(foregroundColor: .white.opacity(0.85)))
                .accessibilityIdentifier("snap-compare-reset")
            }
        }
        .font(.footnote.weight(.semibold))
    }
}

/// 小さなMetal描画面を最近傍で拡大し、同じ波形の縁だけを切り出す。
@MainActor
private final class PixelDetailContainer: UIView {
    let metalView: MTKView
    var pixelScale: CGFloat = 1

    init(renderer: WaveformRenderer) {
        metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = true
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)
        metalView.sampleCount = WaveformRenderer.rasterSampleCount
        metalView.autoResizeDrawable = false
        metalView.drawableSize = PixelSnapComparisonModel.drawableSize
        // 拡大時の補間を避け、MSAAで描かれた元の画素の明るさをそのまま観察する。
        metalView.layer.magnificationFilter = .nearest
        // 連続描画は不要。入力やレイアウトが変わったときだけ再描画する。
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.delegate = renderer
        metalView.isAccessibilityElement = false
        addSubview(metalView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let crop = PixelSnapComparisonModel.detailRect
        let size = PixelSnapComparisonModel.drawableSize
        // drawableやLODを変えず、同じ実描画のうち波形の縁がある範囲だけを見せる。
        metalView.frame = CGRect(x: -crop.minX * pixelScale, y: -crop.minY * pixelScale,
                                 width: size.width * pixelScale, height: size.height * pixelScale)
        metalView.drawableSize = size
        metalView.setNeedsDisplay()
    }
}

@MainActor
private struct PixelSnapMetalView: UIViewRepresentable {
    let renderer: WaveformRenderer
    let offsetPx: Double
    let displayScale: Double
    let identifier: String
    let title: String

    func makeUIView(context: Context) -> PixelDetailContainer {
        let view = PixelDetailContainer(renderer: renderer)
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = "\(title) waveform detail, enlarged 24 times"
        return view
    }

    // 入力値はモデル側のプロバイダーから読む。ここでは既存ビューに再描画を要求する。
    func updateUIView(_ view: PixelDetailContainer, context: Context) {
        view.pixelScale = PixelSnapComparisonModel.magnification / displayScale
        view.accessibilityValue = String(format: "Camera input offset %.2f pixels", offsetPx)
        view.setNeedsLayout()
        view.metalView.setNeedsDisplay()
    }
}
