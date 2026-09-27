// swift-tools-version: 6.1
//
//  MetalWaveformKit — PCM の解析と Metal による波形描画
//
//  機能ごとに独立したプロダクトとして導入できる:
//
//   - WaveformCore     投影式 + LOD 解析（純ロジック。自前描画でも使える）
//   - WaveformMetal    Metal レンダラー + シェーダ（WaveformCore に依存）
//   - WaveformSwiftUI  SwiftUI ラッパー（WaveformMetal に依存・iOS のみ実体）
//   - BeatGrid         拍クオンタイズ / 境界計算（依存なし。波形なしでも使える）
//   - MetalWaveformKit 上記モジュールをまとめて公開（1 import で利用）
//
//  Examples/RenderingDemo は描画専用の iOS サンプル。音声再生は利用側で実装する。
//

import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "MetalWaveformKit",
    platforms: [
        .iOS(.v17),
        // macOSでも解析とMetal描画を利用・検証できるようにする
        .macOS(.v14),
    ],
    products: [
        .library(name: "MetalWaveformKit", targets: ["MetalWaveformKit"]),
        .library(name: "WaveformCore", targets: ["WaveformCore"]),
        .library(name: "WaveformMetal", targets: ["WaveformMetal"]),
        .library(name: "WaveformSwiftUI", targets: ["WaveformSwiftUI"]),
        .library(name: "BeatGrid", targets: ["BeatGrid"]),
    ],
    targets: [
        // ── 機能モジュール ──
        .target(name: "WaveformCore", swiftSettings: swift6),
        .target(name: "BeatGrid", swiftSettings: swift6),
        .target(
            name: "WaveformMetal",
            dependencies: ["WaveformCore"],
            // シェーダをモジュールのリソースとして扱う。Xcode のビルドでは
            // default.metallib へコンパイルされ、Bundle.module から読み込める。
            resources: [.process("Shaders.metal")],
            swiftSettings: swift6
        ),
        .target(
            name: "WaveformSwiftUI",
            dependencies: ["WaveformMetal"],
            swiftSettings: swift6
        ),
        // ── 公開 API をまとめるモジュール ──
        .target(
            name: "MetalWaveformKit",
            dependencies: ["WaveformCore", "BeatGrid", "WaveformMetal", "WaveformSwiftUI"],
            swiftSettings: swift6
        ),
        // ── テスト（モジュール単位） ──
        .testTarget(name: "WaveformCoreTests", dependencies: ["WaveformCore"], swiftSettings: swift6),
        .testTarget(name: "WaveformMetalTests", dependencies: ["WaveformMetal", "WaveformCore"], swiftSettings: swift6),
        .testTarget(name: "WaveformMetalGPUTests", dependencies: ["WaveformMetal", "WaveformCore"], swiftSettings: swift6),
        .testTarget(name: "BeatGridTests", dependencies: ["BeatGrid"], swiftSettings: swift6),
    ]
)
