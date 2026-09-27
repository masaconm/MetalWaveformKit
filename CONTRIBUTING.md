# Contributing

See the [package architecture](docs/ARCHITECTURE.md) ([日本語](docs/ARCHITECTURE.ja.md)) for module boundaries and [getting started](docs/GETTING_STARTED.md) ([日本語](docs/GETTING_STARTED.ja.md)) for integration.

## Report a bug

Open an issue in [GitHub Issues](https://github.com/masaconm/MetalWaveformKit/issues). Include the package version, device/OS, Xcode version, drawable size, sample rate/duration, zoom, cue times, expected behavior and reproduction steps. Use generated or redistributable sample data. The included RenderingDemo is a useful starting point.

## Test a change

Use Xcode with Swift 6.1 or later and the Metal compiler. From the package root on a Metal-capable Mac, run:

```sh
swift test
swift test -c release
xcodebuild build \
  -project Examples/RenderingDemo/RenderingDemo.xcodeproj \
  -scheme RenderingDemo \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Without a GPU device, add `--skip WaveformMetalGPUTests` to the test commands. This is the CPU-only CI path and does not validate rendered pixels. Rendering changes and releases require a full GPU run. Record the environment and results in your pull request. See [validation](docs/VALIDATION.md) for tested environments and limitations.

## Submit a pull request

Keep each pull request focused on one change. Explain the problem, the resulting behavior and how you checked it. Add regression coverage where behavior changes and describe measurement conditions for performance claims. Update both READMEs, affected guides and the changelog when changing public usage.

Keep audio-engine behavior outside the rendering modules. Swift implementation comments are written in Japanese; identifiers and public UI labels use English. `QuickStartView.swift` is compiled with the example; keep its copies in the getting started guides and the factory in both READMEs synchronized.

The initial API may change before 1.0.0. Record breaking changes explicitly in the changelog. Contributions are under the repository's MIT license.
