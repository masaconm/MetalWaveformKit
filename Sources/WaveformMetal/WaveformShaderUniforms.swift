//
//  WaveformShaderUniforms.swift
//  WaveformMetal
//
//  CPU と Shaders.metal の間で受け渡すデータ。フィールド順と型を一致させる。
//

import Foundation
import WaveformCore

// MARK: - GPU へ渡す uniform

/// 毎フレーム GPU へ渡す視界情報。
///
/// - Important: Shaders.metal の `ViewportUniforms` 構造体と
///   メモリレイアウト（float 8 つ = 32 バイト）を一致させること。
///   シェーダとレイアウトを共有するため、WaveformCore ではなく
///   このモジュール（シェーダと同居）に定義する。
nonisolated struct ViewportUniforms {
    /// 1 秒あたりの drawable ピクセル数。CPU と GPU で同じ Float 値を使う。
    var pixelsPerSecond: Float
    /// カメラの開始位置の整数部。スナップ有効時は最寄りの整数に丸めた値。
    var cameraStartPx: Float
    /// スナップ無効時に保持する 1 ピクセル未満の端数。有効時は 0。
    var cameraFractionPx: Float
    var drawableWidthPx: Float
    /// 入力振幅を NDC の Y 座標に写す倍率。
    var amplitudeScale: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0

    init(viewport: WaveformViewport, drawableWidthPx: Double, snap: Bool, amplitudeScale: Float) {
        self.drawableWidthPx = Float(max(drawableWidthPx, 1))
        // CPU と GPU で同じ Float の縮尺を使い、ピクセル座標で丸める。
        // 丸めた時刻を Float の秒数に戻すと、ピクセルへの整列が失われる。
        pixelsPerSecond = self.drawableWidthPx / Float(max(viewport.viewportSec, 0.001))
        let camera = viewport.visibleStartSec * Double(pixelsPerSecond)
        let wholePixel = snap ? camera.rounded() : floor(camera)
        cameraStartPx = Float(wholePixel)
        // 整数部と小数部を分け、カメラの大きな絶対位置を Float へ変換するときも
        // 1 ピクセル未満の移動量を残す。時刻や整数部自体には Float の精度限界がある。
        cameraFractionPx = snap ? 0 : Float(camera - wholePixel)
        self.amplitudeScale = amplitudeScale
    }
}

// MARK: - GPU へ渡すマーカー uniform

/// 縦線マーカー（プレイヘッド / キュー / グリッド）1 種ぶんの描画パラメータ。
///
/// - Important: Shaders.metal の `MarkerUniforms` とメモリレイアウトを
///   一致させること（float 8 つ = 32 バイト）。
nonisolated struct MarkerUniforms {
    /// 先頭マーカーの時刻（秒）
    var timeSec: Float
    /// インスタンス描画時の間隔（秒）。単発マーカーは 0
    var intervalSec: Float
    /// 線の半分の太さ（NDC 単位）
    var halfWidthNDC: Float
    /// 線の上端と下端（NDC）。画面全高に描く場合はそれぞれ 1 と -1。
    var topNDC: Float
    var bottomNDC: Float
    /// 再生線だけは画面座標を使い、カメラの丸めによる中央の微動を防ぐ。
    var screenCenterNDC: Float = 0
    /// 0 は時刻の投影、0 以外は screenCenterNDC による位置指定。
    var usesScreenPosition: Float = 0
    var pad2: Float = 0
}
