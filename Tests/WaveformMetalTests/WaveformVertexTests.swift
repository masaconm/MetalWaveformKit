//
//  WaveformVertexTests.swift
//  WaveformMetalTests
//
//  頂点がバケット中心の時刻とmin/max振幅から作られ、画面座標を持たないことを検証する。
//

import Foundation
import Testing
import WaveformCore
@testable import WaveformMetal

struct WaveformVertexTests {

    @Test("頂点配列は time-domain のまま焼き込まれる（ズーム・スクロールで不変な前提）")
    func vertexArrayBakesTimeDomainGeometry() {
        let samples = [Float](repeating: 0.5, count: WaveformAnalyzer.baseFramesPerBucket * 3)
        let level = WaveformAnalyzer.analyze(samples: samples, sampleRate: 44_100).levels[0]
        let vertices = WaveformRenderer.makeVertexArray(level: level)

        // 1バケットに下端・上端の2頂点を置く。Floatの時刻比較には1e-6秒を許容する。
        #expect(vertices.count == level.bucketCount * 2)
        for bucket in 0..<level.bucketCount {
            // 頂点の x はスクリーン座標ではなく「バケット中心の時刻」
            let expectedTime = (Float(bucket) + 0.5) * Float(level.bucketDurationSec)
            #expect(abs(vertices[bucket * 2].x - expectedTime) < 1e-6)
            #expect(abs(vertices[bucket * 2 + 1].x - expectedTime) < 1e-6)
            // (lo, hi) ペアの順序
            #expect(vertices[bucket * 2].y <= vertices[bucket * 2 + 1].y)
        }
    }
}
