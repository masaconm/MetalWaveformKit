# Tested environments and limitations

[Back to README](../README.md) · [日本語](VALIDATION.ja.md)

## Tested environments

The following checks were completed as of September 27, 2026.

| Component | Environment and checks |
| --- | --- |
| Package | Apple Silicon Mac, macOS 27.0, Xcode 27.1, Swift 6.4. CPU and Metal image tests passed in Debug and Release |
| iOS sample | Debug and Release builds for iOS Simulator passed. Waveform display, controls, and rotation were checked on iPhone 16 and iPad Air 11-inch (M3) simulators running iOS 18.6 |

Builds with the minimum supported Swift version, 6.1, and operation on every supported OS version have not been verified.

## Limitations

Sustained frame rates on physical devices, external-display behavior, and peak memory use with long tracks remain unverified. Assess performance in your app using the [physical-device guide](EXAMPLES.md#check-motion-on-a-physical-device).

Your app manages audio playback and synchronization. This package does not measure audio-output latency or display synchronization with audio.

See [Rendering design](DESIGN.md) for pixel snapping, waveform precision, and the scope of HUD measurements.

## Run the tests

The [contributing guide](../CONTRIBUTING.md#test-a-change) describes how to run tests and build the sample. GPU image tests require a Mac with a usable Metal device.
