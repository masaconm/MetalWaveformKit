# Security Policy

## Supported versions

Security fixes are applied to the latest released version only. The API may change before 1.0.0, so upgrade to the newest tag before reporting.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |

## Report a vulnerability

Do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting from the repository's **Security** tab ("Report a vulnerability"). If that option is not available, contact the maintainer through the [masaconm](https://github.com/masaconm) GitHub profile.

Include the package version, the affected module (`WaveformCore`, `WaveformMetal`, `WaveformSwiftUI`, `BeatGrid` or the `MetalWaveformKit` umbrella), the input that triggers the problem and the observed effect. Generated or redistributable sample data is preferred.

## Scope

This package renders waveform data supplied by the host app. It performs no networking, file access or audio playback. Reports about crashes or memory issues caused by malformed PCM input, frame input or cue data are in scope. Issues in the host app's audio pipeline are out of scope.

You will receive an acknowledgement within 7 days. Fixes are published as a new tag and recorded in the [changelog](CHANGELOG.md).
