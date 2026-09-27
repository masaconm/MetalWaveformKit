# Getting started

English | [日本語](GETTING_STARTED.ja.md) · [Back to README](../README.md)

Add the `MetalWaveformKit` product to an iOS 17+ SwiftUI app using the [installation instructions](../README.md#installation). This guide displays static generated data; no audio file or microphone permission is needed.

## Add a minimal view

1. Save the following code in a Swift file in your app.
2. Present `QuickStartView()` from your app.

The view analyzes one second of PCM and displays a one-second window centered at 0.5 seconds.

```swift
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
```

This is the same code as [QuickStartView.swift](../Examples/RenderingDemo/RenderingDemo/QuickStartView.swift), compiled by the included Xcode project.

The included app opens the interactive RenderingDemo by default. To try this minimal view there, change the `WindowGroup` content to `QuickStartView()`.

`Task.detached` keeps analysis off the main actor and returns an immutable result. Retain the renderer in `@State` or a screen model for the view's lifetime; the underlying `MTKView` keeps only a weak reference to it.

## Preview in Xcode Canvas

1. Open `RenderingDemoApp.swift` in the included project.
2. Choose **Editor → Canvas** to show the Canvas.
3. Resume the preview.

**Rendering demo** shows the interactive screen; **Minimal integration** shows the minimal view from this guide. Both use generated data and produce no audio.

## Follow audio playback

Your app handles audio decoding and playback. To display its playback position, supply PCM data to the analyzer and connect the renderer to your audio clock.

### Prepare the PCM data

Supply the analyzer with:

- One channel of PCM. For multichannel data, choose the displayed channel or downmix policy in your app.
- Finite `Float` amplitudes, normally in `-1...1`. The analyzer does not normalize amplitudes.
- The actual sample rate in Hz, as a finite, positive value.

### Map display time to track position

For moving playback, set `timedFrameInputProvider`. The iOS view passes `CADisplayLink.targetTimestamp`: a host timestamp in seconds using the same time domain as `CACurrentMediaTime()`.

This timestamp is **not a track position**. Map it into your audio clock's track seconds, then return playback time, zoom and cue times together.

The renderer calls one provider per frame on the main actor:

- A non-`nil` `timedFrameInputProvider` takes priority.
- Otherwise, it calls the existing no-argument `frameInputProvider`. Set the timed provider to `nil` to return to that path.

Direct `draw(in:)` calls use `CACurrentMediaTime()` as the host-time fallback. Custom display drivers can pass their target time to `draw(in:atHostTime:)`.

This helper calculates the track position at the target display time from an audio-clock anchor. Pass the host time and track position of the **same audio instant**, with host ticks converted to seconds in the required time domain:

```swift
import QuartzCore
import MetalWaveformKit

@MainActor
func setPlaybackAnchor(
    on renderer: WaveformRenderer,
    hostTime: CFTimeInterval,
    trackSeconds: Double,
    playbackRate: Double,
    zoomScale: Double = 4
) {
    renderer.timedFrameInputProvider = { targetHostTime in
        let position = trackSeconds + (targetHostTime - hostTime) * playbackRate
        return WaveformFrameInput(playheadSec: position, zoomScale: zoomScale)
    }
}
```

### Keep the playback anchor current

`playbackRate` is track seconds per host second: `1` for normal playback, `0` when paused. Refresh the anchor from a safely transferred audio-clock snapshot and after a seek, loop, pause or rate change.

When updating playback input:

- Handle track bounds and looping in the app.
- Do not pair an old audio position with the time its callback happens to reach the main actor.
- Do not read audio-thread mutable state directly.
- If zoom or cues can change during playback, read their current values together in the same provider.

### Frame input and settings

| Input / setting | Meaning |
| --- | --- |
| `playheadSec` | Playback position in seconds from the start of the track |
| `zoomScale` | Window duration is `16 / zoomScale` seconds; the example uses 1–64 |
| `cueTimesSec` | Marker positions in seconds |
| `beatIntervalSec` | Constant beat interval; for example, `0.5` seconds at 120 BPM |

Audio render time can differ from audible speaker-output time. This package does not measure or compensate for output latency.

### Manage the renderer and view lifetime

Use `[weak self]` when closures refer to the renderer's owner, as in the included example, to avoid a retain cycle.

To change tracks, assign new `analysis` to the existing renderer. `WaveformMetalView` also accepts a replacement renderer during SwiftUI updates; recreating the view identity is not required.

The iOS view stops its display link while detached or inactive and invalidates it on teardown. Resuming uses a fresh target timestamp, so the caller's audio clock determines whether playback advanced during the interruption.

The view requests the screen's maximum refresh rate, but the OS determines the actual rate; ProMotion does not guarantee 120 fps. See [rendering design](DESIGN.md#display-scheduling-and-view-lifetime) for lifecycle and direct `MTKView` integration.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Renderer initialization returns `nil` | Metal device, Metal compiler and bundled shaders are available |
| Waveform does not move | `playheadSec` changes; the minimal example intentionally uses a fixed time |
| No waveform is visible | PCM is nonempty, contains nonzero amplitudes, and is inside the visible range |
| `WaveformMetalView` is missing on macOS | The wrapper is iOS-only; connect `WaveformRenderer` to an `MTKView` on macOS |

See [rendering design](DESIGN.md) for `MTKView` configuration and precision, or [package architecture](ARCHITECTURE.md) to choose individual products.
