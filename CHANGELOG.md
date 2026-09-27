# Changelog

## 0.1.0

- Provide five SwiftPM products: the `MetalWaveformKit` umbrella, waveform analysis, Metal rendering, iOS SwiftUI integration and beat calculations.
- Analyze PCM into min/max LOD levels, cache vertex buffers and draw the visible range with pixel snapping and 4× MSAA.
- Share one frame input across waveform, playhead, cue markers and beat grid. Keep the default synced playhead at screen center; waveform, grid and cues share the snapped projection.
- Accept display target timestamps through `timedFrameInputProvider` and `draw(in:atHostTime:)`, while supporting the no-argument input provider. The app maps host timestamps to track positions.
- Drive the iOS view with a screen-specific `CADisplayLink`, stop drawing while detached or inactive, and support renderer replacement during SwiftUI updates.
- Include RenderingDemo, an iPhone/iPad app with generated data, animation, zoom, up to eight seekable cues, a return-to-start control and a rendering HUD. The sample has no audio engine or bundled music.
- Provide a pixel-inspection screen that magnifies actual snapped and unsnapped rendering 24×, with automatic and manual motion controls. Respect Reduce Motion by opening it paused.
- Support English and Japanese explanations with a saved language preference. Keep titles and control labels in English.
- Include CPU calculation tests and Metal image regression tests, with their CI coverage and measurement limits documented separately.
- Provide English/Japanese integration, architecture, design and sample guides. Compile the quick-start view as part of the sample app.
- Add a `RenderingDemo Performance` scheme that runs an optimized Release build without the debugger, with physical-device setup instructions.
- Require Swift tools 6.1 and Swift 6 language mode.

The API may change before 1.0.0. See [validation](docs/VALIDATION.md) for tested conditions and known limits.
