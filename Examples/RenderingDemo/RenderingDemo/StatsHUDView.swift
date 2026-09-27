//
//  StatsHUDView.swift
//  RenderingDemo
//
//  責務: レンダラーが集計した描画統計を、起動時から4行で表示する。
//

import MetalWaveformKit
import SwiftUI

/// 0.5秒ごとの集計結果を表示する。集計前は初期値のゼロが表示される。
/// cpu は描画処理のCPU側の平均経過時間で、GPUの実行時間や音声処理は含まない。
struct StatsHUDView: View {
    let stats: RenderStats

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(stats.fps, specifier: "%.0f") fps  |  cpu \(stats.cpuFrameMs, specifier: "%.2f") ms")
            Text("geometry rebuilds/s: \(stats.rebuildsPerSecond, specifier: "%.1f")")
                .accessibilityIdentifier("hud-rebuilds")
            Text("LOD \(stats.lodLevelIndex) (\(stats.lodBucketMs, specifier: "%.2f") ms/bucket)  verts \(stats.drawnVertexCount)")
                .accessibilityIdentifier("hud-lod")
            // CPU上で求めた再生位置の投影差の最大値。通常の同期モードではゼロになる。
            // 0.1px単位の表示から、GPUの画素誤差や音声との同期精度は判断できない。
            Text("playhead drift (peak): \(stats.playheadDriftPx, specifier: "%.1f") px")
                .accessibilityIdentifier("hud-drift")
                .foregroundStyle(stats.playheadDriftPx > 1 ? .red : .green)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rendering-stats-hud")
        // 波形のピンチ操作をHUDで遮らない。
        .allowsHitTesting(false)
    }
}
