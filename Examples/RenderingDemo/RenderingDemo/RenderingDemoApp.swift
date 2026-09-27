import Metal
import Observation
import QuartzCore
import SwiftUI
import UIKit
import MetalWaveformKit

@main
struct RenderingDemoApp: App {
    var body: some Scene {
        WindowGroup { RenderingDemoView() }
    }
}

/// 合成波形の表示時計、操作状態、レンダラーの生成をまとめる。音声再生は行わない。
@MainActor
@Observable
final class RenderingDemoModel {
    private(set) var renderer: WaveformRenderer?
    private(set) var error: String?
    private(set) var running = false
    var zoom = 4.0
    var pixelSnap = true
    private(set) var cues = [30.0, 32.0, 34.0]
    private(set) var lastMarkedCue: Double?
    var stats = RenderStats.zero
    // 停止・シーク時の表示秒と、その時点のホスト時刻を対で保持する。
    private var anchorTime = 32.0
    private var anchorClock = CACurrentMediaTime()

    var currentTime: Double {
        playbackTime(atHostTime: CACurrentMediaTime())
    }

    /// CACurrentMediaTime と同じ基準のホスト時刻を、合成トラック内の秒数へ変換する。
    /// 描画では表示予定時刻を使い、コールバック到着時刻のばらつきを位置に持ち込まない。
    private func playbackTime(atHostTime hostTime: CFTimeInterval) -> Double {
        let elapsed = running ? max(0, hostTime - anchorClock) : 0
        return min(60, max(0, anchorTime + elapsed))
    }

    /// 合成と解析をバックグラウンドで済ませ、MainActor 上で描画と統計の通知先を接続する。
    func prepare() async {
        guard renderer == nil, error == nil else { return }
        // 表示用の規則的なデータだけを生成する。音源ファイルや再生処理は持たない。
        let analysis = await Task.detached {
            let rate = 48_000.0
            let samples = (0..<Int(rate * 60)).map { i -> Float in
                let time = Double(i) / rate
                let phase = time.truncatingRemainder(dividingBy: 0.5)
                return Float(sin(time * 2 * .pi * 110) * exp(-phase * 22) * 0.8)
            }
            return WaveformAnalyzer.analyze(samples: samples, sampleRate: rate)
        }.value
        guard !Task.isCancelled else { return }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = WaveformRenderer(device: device) else {
            error = "Metal rendering is unavailable."
            return
        }
        renderer.analysis = analysis
        renderer.beatIntervalSec = 0.5
        // WaveformMetalView が渡す表示予定時刻から、このフレームで共有する入力を作る。
        // モデルが renderer を保持するため、逆向きの参照は weak にする。
        renderer.timedFrameInputProvider = { [weak self] hostTime in
            guard let self else { return WaveformFrameInput() }
            return WaveformFrameInput(
                playheadSec: self.playbackTime(atHostTime: hostTime), zoomScale: self.zoom,
                cueTimesSec: self.cues, unsnappedCamera: !self.pixelSnap)
        }
        renderer.onStats = { [weak self] in
            self?.stats = $0
            self?.stopAtEndIfNeeded()
        }
        self.renderer = renderer
    }

    /// 表示位置だけを移す。先頭へ戻る操作やキュー移動でも、再生・停止状態を保つ。
    func seek(to time: Double) {
        anchorTime = min(60, max(0, time))
        anchorClock = CACurrentMediaTime()
    }

    func toggleAnimation() {
        // 末尾で止まった後も、再び描画の動きを確認できるよう32秒から再開する。
        seek(to: !running && currentTime >= 60 ? 32 : currentTime)
        running.toggle()
    }

    func markCurrentTime() {
        // 48 kHz のサンプル位置へ丸め、同じ位置は重複登録しない。最大8件を時刻順に並べる。
        // 拍へのクオンタイズや、次の拍でのジャンプ予約はこのサンプルでは扱わない。
        let time = (currentTime * 48_000).rounded() / 48_000
        if !cues.contains(time), cues.count < 8 {
            cues.append(time)
            cues.sort()
        }
        lastMarkedCue = time
    }

    func clearCues() {
        cues.removeAll()
        lastMarkedCue = nil
    }

    // 時計は60秒で頭打ちになる。統計通知時にボタンの表示も停止状態へそろえる。
    private func stopAtEndIfNeeded() {
        guard running, currentTime >= 60 else { return }
        seek(to: 60)
        running = false
    }
}

/// 操作と解説を並べる画面。描画入力の更新はモデルに任せる。
struct RenderingDemoView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 300
    @ScaledMetric(relativeTo: .footnote) private var markerButtonHeight: CGFloat = 44
    @State private var model = RenderingDemoModel()
    @State private var pinchAnchor: Double?
    @State private var showingPixelComparison = false
    @AppStorage("explanationLanguage") private var explanationLanguage: ExplanationLanguage = .preferred

    var body: some View {
        GeometryReader { geometry in
            let isPortrait = geometry.size.height >= geometry.size.width
            let contentWidth = max(0, geometry.size.width - 32)
            // iPhone横向きで幅が足りる場合は等幅2列にする。iPadや大きな文字では一列を使う。
            let sideBySide = UIDevice.current.userInterfaceIdiom == .phone
                && (horizontalSizeClass == .regular || verticalSizeClass == .compact)
                && !isPortrait
                && contentWidth >= minimumColumnWidth * 2 + 16
                && !dynamicTypeSize.isAccessibilitySize
            let compact = sideBySide && verticalSizeClass == .compact
            let fitsPortrait = UIDevice.current.userInterfaceIdiom == .phone
                && isPortrait && !dynamicTypeSize.isAccessibilitySize
            let verticalMargin: CGFloat = compact ? 8 : (fitsPortrait ? 12 : 16)
            let contentHeight = max(0, geometry.size.height - verticalMargin * 2)
            let layout = RenderingDemoLayout(
                viewportSize: CGSize(width: contentWidth, height: contentHeight),
                arrangement: sideBySide ? .twoColumns : (fitsPortrait ? .fittedColumn : .scrollingColumn),
                spacing: compact || fitsPortrait ? 8 : 16
            )

            ScrollView {
                // 配置モードだけを切り替え、回転してもMetalビューと描画状態を保持する。
                layout {
                    header
                        .layoutValue(key: RenderingDemoSectionKey.self, value: .header)
                    waveform
                        .layoutValue(key: RenderingDemoSectionKey.self, value: .waveform)
                    transportControls(compact: compact)
                        .disabled(model.renderer == nil)
                        .layoutValue(key: RenderingDemoSectionKey.self, value: .transport)
                    markerControls
                        .disabled(model.renderer == nil)
                        .layoutValue(key: RenderingDemoSectionKey.self, value: .cues)
                    ViewThatFits(in: .vertical) {
                        settingsPanel(minimumHeight: sideBySide ? contentHeight : nil)
                        ScrollView { settingsPanel() }
                            .scrollBounceBehavior(.basedOnSize)
                    }
                    .disabled(model.renderer == nil)
                    .layoutValue(key: RenderingDemoSectionKey.self, value: .scenarios)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, verticalMargin)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(red: 0.09, green: 0.10, blue: 0.13).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await model.prepare() }
        .sheet(isPresented: $showingPixelComparison) {
            if let analysis = model.renderer?.analysis {
                PixelSnapComparisonView(analysis: analysis, language: $explanationLanguage)
                    .preferredColorScheme(.dark)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                Text("MetalWaveformKit").font(.headline)
                Text("Rendering demo · no audio")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            // 左右に同じ幅を確保し、言語メニューがあってもタイトルを中央に保つ。
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 0 : 60)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .trailing) {
                if !dynamicTypeSize.isAccessibilitySize {
                    ExplanationLanguageMenu(language: $explanationLanguage)
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                ExplanationLanguageMenu(language: $explanationLanguage)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rendering-header")
    }

    @ViewBuilder
    private var waveform: some View {
        if let renderer = model.renderer {
            WaveformMetalView(renderer: renderer)
                .overlay(alignment: .topLeading) {
                    StatsHUDView(stats: model.stats)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("rendering-waveform")
                // ジェスチャー開始時の倍率を基準にする。更新済みの倍率へ繰り返し乗算しない。
                .gesture(MagnifyGesture()
                    .onChanged { value in
                        if pinchAnchor == nil { pinchAnchor = model.zoom }
                        model.zoom = min(64, max(1, (pinchAnchor ?? model.zoom) * value.magnification))
                    }
                    .onEnded { _ in pinchAnchor = nil })
        } else if let error = model.error {
            Text(error).foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Preparing waveform…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transportControls(compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 10) {
            // 20 Hz の更新は時刻ラベル用。Metal のフレーム入力は表示予定時刻から別に取得する。
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                HStack {
                    Text("\(model.currentTime, specifier: "%.3f") s")
                        .font(.system(compact ? .footnote : .title3, design: .monospaced))
                        .accessibilityIdentifier("transport-current-time")
                    Text("/ 60 s").font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: compact ? 10 : 12))
            layout {
                HStack(spacing: 8) {
                    Button { model.seek(to: 0) } label: {
                        Image(systemName: "backward.end")
                            .font(.system(size: compact ? 20 : 24, weight: .medium))
                            .frame(width: compact ? 48 : 60, height: compact ? 44 : 48)
                    }
                    .buttonStyle(HardwareButtonStyle(foregroundColor: .white.opacity(0.85)))
                    .accessibilityLabel("Return to beginning")
                    .accessibilityIdentifier("return-to-start")
                    .help("Return to beginning")

                    Button(action: model.toggleAnimation) {
                        Image(systemName: model.running ? "pause" : "play")
                            .font(.system(size: compact ? 22 : 26, weight: .medium))
                            .offset(x: model.running ? 0 : 1)
                            .frame(width: compact ? 48 : 60, height: compact ? 44 : 48)
                    }
                    .buttonStyle(HardwareButtonStyle(
                        foregroundColor: model.running ? Color(red: 0.48, green: 1, blue: 0.24) : .white.opacity(0.85),
                        illuminated: model.running
                    ))
                    .accessibilityLabel(model.running ? "Pause animation" : "Animate waveform")
                    .accessibilityIdentifier("toggle-animation")
                    .help(model.running ? "Pause animation" : "Animate waveform")
                }
                VStack(spacing: 2) {
                    Slider(value: $model.zoom, in: 1...64)
                        .accessibilityLabel("Zoom")
                    Text("Zoom ×\(model.zoom, specifier: "%.1f")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("zoom-detail")
                }
            }
        }
    }

    /// SET CUE は現在位置を登録し、番号ボタンはその時刻へ即座に移動する。
    private var markerControls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button(action: model.markCurrentTime) {
                Text("SET CUE").padding(.horizontal, 12)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 44, minHeight: markerButtonHeight)
            }
            .buttonStyle(HardwareButtonStyle(foregroundColor: .teal))
            .disabled(model.cues.count >= 8)
            .accessibilityLabel("Set cue at current time")
            .accessibilityIdentifier("mark-current-time")

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.cues.enumerated()), id: \.element) { index, time in
                            Button { model.seek(to: time) } label: {
                                Text("\(index + 1)")
                                    .frame(width: markerButtonHeight, height: markerButtonHeight)
                            }
                            .buttonStyle(HardwareButtonStyle(foregroundColor: .orange))
                            .accessibilityLabel("Jump to cue \(index + 1)")
                            .accessibilityValue(String(format: "%.3f s", time))
                            .accessibilityIdentifier("cue-\(index + 1)")
                            .help(String(format: "Jump to %.3f s", time))
                            .id(time)
                        }
                    }
                    // 空のHStackも番号ボタンと同じ高さにし、ScrollView自体の領域を保つ。
                    .frame(height: markerButtonHeight)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(minWidth: 44, maxWidth: .infinity)
                .frame(height: markerButtonHeight + 8)
                .accessibilityIdentifier("cue-strip")
                .onChange(of: model.lastMarkedCue) { _, time in
                    if let time { proxy.scrollTo(time, anchor: .center) }
                }
            }

            Button(role: .destructive, action: model.clearCues) {
                Text("Clear").padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: markerButtonHeight)
            }
            .buttonStyle(HardwareButtonStyle(foregroundColor: .red))
            .disabled(model.cues.isEmpty)
            .accessibilityLabel("Clear markers")
            .accessibilityIdentifier("clear-markers")
        }
        .font(.footnote.weight(.semibold))
        // 番号列の高さを固定し、空のときも操作部の位置を保つ。
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 4 : 0)
    }

    // 二列配置では説明を縦に配分する。一列配置では内容に必要な高さで配置する。
    private func settingsPanel(minimumHeight: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Pixel-snapped camera", isOn: $model.pixelSnap)
                    .accessibilityIdentifier("pixel-snap")
                Text(verbatim: explanationLanguage.text("ON rounds camera movement to pixels; OFF preserves fractions. The difference is at most half a pixel and can be invisible while paused."))
                .accessibilityIdentifier("explanation-camera-snap")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button { showingPixelComparison = true } label: {
                Label("Inspect pixels", systemImage: "plus.magnifyingglass")
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
            }
            .buttonStyle(HardwareButtonStyle(foregroundColor: .teal))
            .accessibilityIdentifier("inspect-pixels")
            if minimumHeight != nil { Spacer(minLength: 0) }
            Text(verbatim: explanationLanguage.text("Use the play button to animate and the return-to-start button to return to the beginning (0 s). Pinch or use the slider to zoom."))
                .accessibilityIdentifier("explanation-main-controls")
                .foregroundStyle(.secondary)
            if minimumHeight != nil { Spacer(minLength: 0) }
            Text(verbatim: explanationLanguage.text("SET CUE saves the current time. Tap a numbered cue to jump there; swipe the cue row to see more. Clear removes all cues. White lines show 0.5-second beats."))
                .accessibilityIdentifier("explanation-cues")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .frame(minHeight: minimumHeight.map { max(0, $0 - 24) })
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rendering-scenarios")
    }
}

// 操作付きのデモと、導入ガイドの最小ビューをCanvasで確認する。
#Preview("Rendering demo") {
    RenderingDemoView()
}

#Preview("Minimal integration") {
    QuickStartView()
        .preferredColorScheme(.dark)
}
