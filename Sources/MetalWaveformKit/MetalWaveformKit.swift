//
//  MetalWaveformKit.swift
//  MetalWaveformKit
//
//  各モジュールの公開 API をまとめて再公開する。
//  `import MetalWaveformKit` の 1 行で、そのプラットフォームで利用できる API を使える。
//  SwiftUI のラッパーは UIKit を利用できる環境に限定する。
//
//  機能単位で導入したい場合は、Package.swift のプロダクトから
//  必要なものだけを依存に追加する:
//   - WaveformCore     … 投影式 + LOD 解析（描画エンジン非依存）
//   - WaveformMetal    … Metal レンダラー
//   - WaveformSwiftUI  … SwiftUI ラッパー（iOS のみ）
//   - BeatGrid         … 拍クオンタイズ / 境界計算
//

@_exported import BeatGrid
@_exported import WaveformCore
@_exported import WaveformMetal
#if canImport(UIKit)
@_exported import WaveformSwiftUI
#endif
