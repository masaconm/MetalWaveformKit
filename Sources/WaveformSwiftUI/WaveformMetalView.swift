//
//  WaveformMetalView.swift
//  WaveformSwiftUI
//
//  責務: SwiftUI と MTKView の接続、表示予定時刻を使う描画ループの管理。
//        MSAA サンプル数など renderer と一致が必要な設定も一元化する。
//  依存: MetalKit / QuartzCore / SwiftUI / UIKit（iOS のみ）
//
//  利用側の責務:
//    - WaveformRenderer の生成と保持。SwiftUI の body の評価ごとに作り直さず、
//      描画中は同じインスタンスを維持する
//    - frameInputProvider または timedFrameInputProvider / onStats の配線
//    - トラック解析結果（analysis）と拍情報のセット
//
//  ```swift
//  @State private var renderer: WaveformRenderer?
//  ...
//  if let renderer {
//      WaveformMetalView(renderer: renderer)
//  }
//  ```
//

#if canImport(UIKit)
import MetalKit
import QuartzCore
import SwiftUI
import UIKit
import WaveformMetal

/// iOS の SwiftUI から波形を表示するための MTKView ラッパー。
///
/// CADisplayLink の表示予定時刻に合わせて描画し、画面やアプリが非アクティブなら停止する。
/// 高リフレッシュレートでの描画を希望するが、実際の頻度は OS が決める。
/// レンダラーの生成、入力 provider の設定、解析結果の用意は利用側で行う。
@MainActor
public struct WaveformMetalView: UIViewRepresentable {

    private let renderer: WaveformRenderer

    /// 設定済みのレンダラーを接続する。描画ループ中は同じインスタンスを保持する。
    public init(renderer: WaveformRenderer) {
        self.renderer = renderer
    }

    /// パイプラインに合う描画形式と MSAA を設定したビューを作る。
    public func makeUIView(context: Context) -> MTKView {
        DisplayLinkedMetalView(renderer: renderer)
    }

    /// SwiftUI が更新されたときに、接続するレンダラーを反映する。
    public func updateUIView(_ view: MTKView, context: Context) {
        // 描画入力は毎フレーム取得する。SwiftUI 更新では renderer の差替えだけ反映する。
        (view as? DisplayLinkedMetalView)?.updateRenderer(renderer)
    }

    /// ビューの破棄に合わせて表示リンクと通知監視を解除する。
    public static func dismantleUIView(_ view: MTKView, coordinator: Void) {
        (view as? DisplayLinkedMetalView)?.dismantle()
    }
}

@MainActor
private final class DisplayLinkedMetalView: MTKView, MTKViewDelegate {
    // SwiftUI 側が所有するレンダラーを参照する。内部ビューだけでは寿命を延ばさない。
    private weak var waveformRenderer: WaveformRenderer?
    private var displayLink: CADisplayLink?
    private weak var displayLinkScreen: UIScreen?
    private var pendingHostTime: CFTimeInterval?
    private var requestedMaximumFPS = 0
    private var observingLifecycle = false
    private var applicationIsActive = false
    private var sceneIsActive = false
    private var isDismantled = false

    init(renderer: WaveformRenderer) {
        waveformRenderer = renderer
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)
        // renderer の rasterSampleCount と一致させ、MSAA の設定不整合を防ぐ。
        sampleCount = WaveformRenderer.rasterSampleCount
        // 内部タイマーと setNeedsDisplay による描画を止め、表示リンクだけを描画元にする。
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 別の window / screen へ移る場合も、古い表示リンクを引き継がない。
        stopDisplayLink()
        if window == nil {
            stopObservingLifecycle()
        } else if !isDismantled {
            applicationIsActive = UIApplication.shared.applicationState == .active
            sceneIsActive = window?.windowScene.map { $0.activationState == .foregroundActive } ?? true
            observeLifecycle()
            updateDisplayLinkState()
        }
    }

    func updateRenderer(_ renderer: WaveformRenderer) {
        guard !isDismantled else { return }
        waveformRenderer = renderer
        renderer.mtkView(self, drawableSizeWillChange: drawableSize)
        updateDisplayLinkState()
    }

    func dismantle() {
        isDismantled = true
        stopDisplayLink()
        stopObservingLifecycle()
        delegate = nil
        waveformRenderer = nil
    }

    /// アプリと、このビューが属する scene の両方が描画可能なときだけ動かす。
    private var canDraw: Bool {
        guard !isDismantled, applicationIsActive, sceneIsActive,
              let window, waveformRenderer != nil,
              UIApplication.shared.applicationState == .active else { return false }
        // 複数 window がある場合、別 scene が active でも自身の scene は描画しない。
        return window.windowScene.map { $0.activationState == .foregroundActive } ?? true
    }

    private func updateDisplayLinkState() {
        guard canDraw, let screen = window?.screen else {
            stopDisplayLink()
            return
        }
        if displayLink != nil {
            guard displayLinkScreen !== screen else { return }
            stopDisplayLink()
        }
        let target = WaveformDisplayLinkTarget(view: self)
        // ビューが属する screen の表示リンクを使い、外部画面の更新時刻にも合わせる。
        guard let link = screen.displayLink(withTarget: target,
                                            selector: #selector(WaveformDisplayLinkTarget.tick(_:))) else { return }
        displayLink = link
        displayLinkScreen = screen
        updateFrameRatePreference(link)
        // ドラッグやピンチの追跡中も同じ表示予定時刻のループを使う。
        link.add(to: .main, forMode: .common)
    }

    private func updateFrameRatePreference(_ link: CADisplayLink) {
        let maximumFPS = max(1, window?.screen.maximumFramesPerSecond ?? 60)
        guard maximumFPS != requestedMaximumFPS else { return }
        requestedMaximumFPS = maximumFPS
        let maximum = Float(maximumFPS)
        // 画面の上限を希望値にする。実際の頻度は端末・電力・OS の判断で変わる。
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximum), maximum: maximum, preferred: maximum
        )
    }

    /// 停止時に前回の表示予定時刻も破棄し、復帰後のフレームへ持ち越さない。
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkScreen = nil
        pendingHostTime = nil
        requestedMaximumFPS = 0
    }

    func displayLinkDidFire(_ link: CADisplayLink) {
        guard link === displayLink else {
            link.invalidate()
            return
        }
        guard canDraw else {
            stopDisplayLink()
            return
        }
        // 同じ window が別の screen へ移動した場合も、古い画面の予定時刻を使わない。
        guard displayLinkScreen === window?.screen else {
            stopDisplayLink()
            updateDisplayLinkState()
            return
        }
        updateFrameRatePreference(link)
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        // targetTimestamp は次の表示予定のホスト秒数。トラック時刻への対応付けは
        // timedFrameInputProvider に任せ、この draw 呼び出しの間だけ保持する。
        pendingHostTime = link.targetTimestamp
        defer { pendingHostTime = nil }
        // MTKView 自身の drawable 管理を保ち、delegate へ表示予定時刻を渡す。
        draw()
    }

    func draw(in view: MTKView) {
        guard canDraw, let waveformRenderer else { return }
        if let pendingHostTime {
            waveformRenderer.draw(in: view, atHostTime: pendingHostTime)
        } else {
            waveformRenderer.draw(in: view)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        waveformRenderer?.mtkView(view, drawableSizeWillChange: size)
    }

    /// アプリ全体の通知と scene ごとの通知を両方監視する。
    /// scene の通知は受信時に自身の windowScene と照合する。
    private func observeLifecycle() {
        guard !observingLifecycle else { return }
        observingLifecycle = true
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(applicationWillDeactivate(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(applicationDidActivate(_:)),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(sceneDidActivate(_:)),
                           name: UIScene.didActivateNotification, object: nil)
    }

    private func stopObservingLifecycle() {
        guard observingLifecycle else { return }
        NotificationCenter.default.removeObserver(self)
        observingLifecycle = false
    }

    @objc private func applicationWillDeactivate(_ notification: Notification) {
        // will 通知時には状態値がまだ active の場合があるため、復帰通知まで止める。
        applicationIsActive = false
        stopDisplayLink()
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        applicationIsActive = true
        updateDisplayLinkState()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        sceneIsActive = false
        stopDisplayLink()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        sceneIsActive = true
        updateDisplayLinkState()
    }
}

/// 表示リンクが View を強参照し続ける循環を作らないための転送先。
@MainActor
private final class WaveformDisplayLinkTarget: NSObject {
    private weak var view: DisplayLinkedMetalView?

    init(view: DisplayLinkedMetalView) {
        self.view = view
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            // dismantle を経ずに View が解放されても、run loop にリンクを残さない。
            link.invalidate()
            return
        }
        view.displayLinkDidFire(link)
    }
}
#endif
