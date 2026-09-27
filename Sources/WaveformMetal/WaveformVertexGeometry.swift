//
//  WaveformVertexGeometry.swift
//  WaveformMetal
//
//  min/max エンベロープを time-domain の頂点配列に変換する純粋な処理。
//  Metal のデバイス・バッファ・描画状態には依存しない。
//

import WaveformCore

nonisolated enum WaveformVertexGeometry {
    /// 頂点の x には画面座標ではなく「トラック時刻」を入れる。
    /// 同じ LOD の配列はズーム・スクロールで変わらず、GPU が毎フレーム投影する。
    /// バケット内の極値は同じ中心時刻へ配置する。極値が現れた正確な時刻は表さない。
    static func makeVertices(level: WaveformLODLevel) -> [SIMD2<Float>] {
        let bucketDuration = Float(level.bucketDurationSec)
        var vertices = [SIMD2<Float>]()
        vertices.reserveCapacity(level.bucketCount * 2)
        for bucket in 0..<level.bucketCount {
            // バケット中心の時刻を x に焼き込む
            let time = (Float(bucket) + 0.5) * bucketDuration
            var lo = level.minMax[bucket * 2]
            var hi = level.minMax[bucket * 2 + 1]
            // 無音区間も見えるよう、振幅の幅を最低 0.008 に広げる。
            // ピクセル単位の固定幅ではなく、実際の太さは描画先の高さで変わる。
            if hi - lo < 0.008 {
                let mid = (hi + lo) * 0.5
                lo = mid - 0.004
                hi = mid + 0.004
            }
            // triangle strip: (t, lo), (t, hi) を交互に並べたリボン
            vertices.append(SIMD2(time, lo))
            vertices.append(SIMD2(time, hi))
        }
        return vertices
    }
}
