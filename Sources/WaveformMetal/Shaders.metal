//
//  Shaders.metal
//  WaveformMetal
//
//  波形本体・キュー・小節グリッドは同じ projectTimeToNDCX() を通る。
//  再生線は画面中央を基準にし、カメラの丸めから独立させる。
//  遅延の再現モードでは、現在時刻との差だけを画面中央からの変位へ写す。
//
//  頂点は (timeSec, amplitude) のまま GPU に置く。既存の LOD バッファは
//  スクロールやズームで再構築せず、可視範囲と uniform、描画命令を更新する。
//  未使用の LOD を選んだときは、描画中にそのバッファを初めて構築する。
//

#include <metal_stdlib>
using namespace metal;

// Swift 側 ViewportUniforms（WaveformShaderUniforms.swift）とレイアウトを一致させる。
struct ViewportUniforms {
    float pixelsPerSecond;
    float cameraStartPx;
    float cameraFractionPx;
    float drawableWidthPx;
    float amplitudeScale;
    float pad0;
    float pad1;
    float pad2;
};

// Swift 側 MarkerUniforms（WaveformShaderUniforms.swift）とレイアウトを一致させる。
struct MarkerUniforms {
    float timeSec;      // 先頭マーカーの時刻
    float intervalSec;  // インスタンス描画時の間隔（単発マーカーは 0）
    float halfWidthNDC; // 線の半分の太さ（NDC）
    float topNDC;
    float bottomNDC;
    float screenCenterNDC;
    float usesScreenPosition;
    float pad2;
};

// 波形・キュー・グリッドで共有する、時刻から NDC X への投影。
// CPU 側の WaveformViewport と同じ座標関係を、ピクセル単位の Float 演算で表す。
static inline float projectTimeToNDCX(float timeSec, constant ViewportUniforms &viewport) {
    // スナップ有効時のカメラ位置は整数ピクセル。
    // fma で乗算と減算をまとめ、絶対時刻の大きな積を先に丸める誤差を抑える。
    // Float の入力精度や最終結果の丸め誤差までなくなるわけではない。
    float pixelX = fma(timeSec, viewport.pixelsPerSecond, -viewport.cameraStartPx) - viewport.cameraFractionPx;
    return (pixelX / viewport.drawableWidthPx) * 2.0 - 1.0;
}

struct RasterVertex {
    float4 position [[position]];
    half4 color;
};

// ── 波形本体 ──────────────────────────────────────────────
// 頂点バッファには (timeSec, amplitude) が入っている。
// x 座標は毎フレーム GPU 側で uniform から求める。
// キャッシュ済みの頂点を CPU で画面座標へ書き換える必要はない。
vertex RasterVertex waveform_vertex(
    const device float2 *vertices [[buffer(0)]],
    uint vid [[vertex_id]],
    constant ViewportUniforms &viewport [[buffer(1)]],
    constant float4 &color [[buffer(2)]]
) {
    float2 timeAmplitude = vertices[vid];
    RasterVertex out;
    out.position = float4(
        projectTimeToNDCX(timeAmplitude.x, viewport),
        timeAmplitude.y * viewport.amplitudeScale,
        0.0,
        1.0
    );
    out.color = half4(color);
    return out;
}

// ── 縦線マーカー（プレイヘッド / キュー / 小節グリッド）───────────
// 頂点バッファを一切持たず、vertex_id と instance_id から
// 4 頂点の矩形を合成する。呼び出し側は viewport、マーカーの値、色を渡す。
vertex RasterVertex marker_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant ViewportUniforms &viewport [[buffer(1)]],
    constant MarkerUniforms &marker [[buffer(2)]],
    constant float4 &color [[buffer(3)]]
) {
    float timeSec = marker.timeSec + marker.intervalSec * float(iid);
    // 再生線は画面座標を使い、波形側のカメラの丸めで中央から動かないようにする。
    float centerX = marker.usesScreenPosition != 0.0
        ? marker.screenCenterNDC
        : projectTimeToNDCX(timeSec, viewport);
    float x = centerX + (((vid & 1u) == 0u) ? -marker.halfWidthNDC : marker.halfWidthNDC);
    float y = (vid < 2) ? marker.bottomNDC : marker.topNDC;

    RasterVertex out;
    out.position = float4(x, y, 0.0, 1.0);
    out.color = half4(color);
    return out;
}

// 単色を出力する。半透明色の合成と MSAA はレンダーパイプライン側で行う。
fragment half4 flat_fragment(RasterVertex in [[stage_in]]) {
    return in.color;
}
