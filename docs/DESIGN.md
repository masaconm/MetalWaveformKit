# Rendering design

English | [日本語](DESIGN.ja.md) · [Back to README](../README.md)

The waveform, playhead, beat grid and cues share a time axis. The app owns playback state and supplies the values needed to draw each frame.

## Share one input snapshot per frame

`WaveformRenderer` reads one frame input on the main actor. If `timedFrameInputProvider` is set, it receives the target host timestamp; otherwise the renderer calls the existing `frameInputProvider`.

Return the track position derived from the audio clock together with the zoom and cue times. The renderer owns no playback engine.

### Host time and track position

`WaveformMetalView` supplies `CADisplayLink.targetTimestamp` to `draw(in:atHostTime:)`. That timestamp uses the same time domain as `CACurrentMediaTime()`, not track seconds.

The caller maps it to an audio-clock position, using a coherent host-time/track-position pair and playback rate. See the [mapping example](GETTING_STARTED.md#follow-audio-playback).

Direct `draw(in:)` calls remain supported and use the current `CACurrentMediaTime()`; a nonfinite explicit host time also falls back to the current time.

The caller owns playback state. Resolving input once per frame prevents different elements from using different snapshots when zoom or cues change between frames.

### Shared projection

The waveform, beat grid and cues share one viewport and its snapped `ViewportUniforms`. Their conceptual mapping is `x = (time - visibleStart) / visibleDuration * drawableWidth`.

GPU calculations use Float, split the camera position into integer and fractional pixel components, and compute coordinates with `fma`. CPU viewport helpers use Double before returning coordinates. These calculations do not guarantee bit-identical CPU/GPU results.

### Playhead position and pixel snapping

In the default synced mode, the playhead's geometric center stays at screen center rather than following the snapped camera.

For the track time represented by the playhead, the shared content projection can differ from that center by up to 0.5 drawable pixels, plus floating-point and rasterization tolerance.

This bound describes the projection, not the exact time of an amplitude extremum within an LOD bucket. Deliberate stale-playhead modes can move the head away from center and are outside that bound.

## Analyze once and cache each LOD

| Frequency | Work |
| --- | --- |
| Once per track | PCM → interleaved min/max buckets → LOD pyramid |
| First use of each LOD | Construct and retain time/amplitude vertices and an `MTLBuffer` |
| Each frame | Read input, choose LOD, compute visible range, update viewport/marker/color uniforms, encode draws |

### Buffer reuse

The waveform draws only visible buckets, with a boundary margin. Reusing a previously visited LOD reuses its buffer.

Assigning `analysis` invalidates all cached levels. The demonstration rebuild flag intentionally recreates the finest level each frame.

### Waveform detail

Level of detail (LOD) controls how much waveform detail is drawn. The finest LOD groups 32 PCM samples per bucket.

Coarse buckets contain the amplitude bounds of finer buckets but do not preserve exact extrema times. Zoom changes visual detail while retaining the shared time mapping.

The viewport uniform is 32 bytes; per-frame work also includes marker/color uniforms, visibility calculations and draw commands.

## Draw beats and cues at supplied times

The optional `BeatGrid` module calculates beat times only. It neither estimates BPM nor schedules audio.

The renderer assumes beat zero at time zero and a constant interval. The initial API does not accept a custom beat origin or variable tempo map. Cue markers are drawn at the supplied times; the app handles cue actions.

## Display scheduling and view lifetime

### Drawing on iOS

`WaveformSwiftUI` creates an iOS `MTKView` using the renderer's MSAA count. An owned `CADisplayLink` calls `MTKView.draw()` and forwards its target timestamp through the delegate.

The view sets `isPaused = true` and `enableSetNeedsDisplay = false`, disabling the internal timer so there is only one scheduling source. The display link runs in common run-loop modes so gestures do not suspend it.

### Stopping, resuming and retaining resources

Drawing stops when the view leaves its window or the app or its scene becomes inactive. Reattachment or activation creates a new display link and uses fresh target timestamps; teardown invalidates the link and removes observers.

A weak callback target prevents a retain cycle. The caller retains the renderer and wires frame input.

SwiftUI updates can replace the renderer in the existing view; assigning new `analysis` is sufficient when only the track changes.

### Screen changes and frame rate

The view uses its window's screen and recreates the display link after a screen change. It requests that screen's maximum frame rate, but the OS, display, power and thermal conditions, and rendering load determine actual delivery.

> **Note:** ProMotion is not a promise of 120 fps.

The example's `RenderingDemo-Info.plist` enables `CADisableMinimumFrameDurationOnPhone`; apps integrating the library must choose their own setting. This opt-in does not guarantee a frame rate.

### Connecting a view on macOS

On macOS, configure your own `MTKView` with these values:

- `colorPixelFormat = .bgra8Unorm`
- `sampleCount = WaveformRenderer.rasterSampleCount`
- `delegate = renderer`

Use the same Metal device and retain the renderer strongly.

Offscreen tests call the same internal `encodeFrame` path as the visible view. This internal seam is not a public export/render-to-image API.

## Measurement

CPU frame time excludes GPU completion and speaker latency.

The HUD drift value compares the screen positions calculated on the CPU for two playhead times; it is useful for the deliberate stale-input modes, not independent proof of rendered alignment.

GPU image tests check rendered output under fixed conditions. See the [GPU test source](../Tests/WaveformMetalGPUTests/) for the conditions and tolerances.

## Inspect rendering behavior

Use defaults for normal integration. These settings demonstrate differences in rendering behavior:

| Setting | Behavior to compare |
| --- | --- |
| `rebuildEveryFrame` | Rebuilding buffers on every frame |
| `playheadProjection` | Projection using deliberately stale playhead input |
| `unsnappedCamera` | Camera behavior with and without pixel snapping |

Pixel snapping can reduce edge shimmer but can make very slow motion appear stepped.

### Shimmer and dropped frames

Display-aligned timing and a fixed playhead do not remove temporal aliasing: a display samples moving detail only once per frame. At high zoom the example's 110 Hz carrier becomes easier to resolve, and can still appear to shimmer or move unevenly even with regularly spaced frames.

This appearance alone does not establish dropped frames; check timing separately.
