//
//  WaveformAnalyzerTests.swift
//  WaveformCoreTests
//
//  PCMから作るmin/maxバケット、LODの時間幅、表示に使うインデックスを検証する。
//

import Foundation
import Testing
@testable import WaveformCore

/// 秒の計算は1e-9、Float振幅の比較は1e-6を許容する。GPUの画素位置は別スイートで検証する。
struct WaveformAnalyzerTests {

    @Test("最細レベルのバケットが正しい min/max を持つ")
    func baseLevelBucketMinMax() {
        // ゼロで埋めたバケットに既知の振幅を置く。2番目のバケットの最小値はゼロのまま。
        var samples = [Float](repeating: 0, count: WaveformAnalyzer.baseFramesPerBucket * 2)
        samples[0] = 0.5
        samples[1] = -0.25
        samples[WaveformAnalyzer.baseFramesPerBucket] = 0.75

        let analysis = WaveformAnalyzer.analyze(samples: samples, sampleRate: 44_100)
        let base = analysis.levels[0]

        #expect(base.bucketCount == 2)
        // インターリーブ配列 [min0, max0, min1, max1]
        #expect(base.minMax[0] == -0.25)
        #expect(base.minMax[1] == 0.5)
        #expect(base.minMax[2] == 0)
        #expect(base.minMax[3] == 0.75)
    }

    @Test("粗いレベルはバケット数が半分になり、細かいレベルのエンベロープを包含する")
    func coarserLevelsHalveAndPreserveEnvelope() {
        let sampleRate: Double = 44_100
        let samples = (0..<(44_100 * 4)).map { Float(sin(Double($0) * 0.01)) }
        let analysis = WaveformAnalyzer.analyze(samples: samples, sampleRate: sampleRate)

        #expect(analysis.levels.count > 1)
        for index in 1..<analysis.levels.count {
            let fine = analysis.levels[index - 1]
            let coarse = analysis.levels[index]
            #expect(abs(coarse.bucketDurationSec - fine.bucketDurationSec * 2) < 1e-9)
            #expect(coarse.bucketCount == (fine.bucketCount + 1) / 2)
            // この入力では全体の最小振幅がLODをまたいで残ることを調べる。
            // 各バケットの両端を個別に比較するテストではない。
            let fineMin = fine.minMax.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).min()!
            let coarseMin = coarse.minMax.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).min()!
            #expect(abs(coarseMin - fineMin) < 1e-6)
        }
    }

    @Test("durationSec がサンプル数 / サンプルレートに一致する")
    func durationMatchesSampleCount() {
        let samples = [Float](repeating: 0, count: 44_100)
        let analysis = WaveformAnalyzer.analyze(samples: samples, sampleRate: 44_100)
        #expect(abs(analysis.durationSec - 1.0) < 1e-9)
    }

    @Test("LOD 選択は 1px 相当を超えない最も粗いレベルを選ぶ")
    func levelSelectionPicksCoarsestFittingBucket() {
        let samples = [Float](repeating: 0.1, count: 44_100 * 30)
        let analysis = WaveformAnalyzer.analyze(samples: samples, sampleRate: 44_100)
        let finestDuration = analysis.levels[0].bucketDurationSec

        // 1px あたりの秒数が最細バケットより小さい -> 最細レベル
        #expect(analysis.levelIndex(forSecondsPerPixel: finestDuration / 2) == 0)

        // 最細バケットが十分小さければ、1px相当の幅に収まる粗いレベルを使う。
        let secondsPerPixel = finestDuration * 10
        let selected = analysis.levels[analysis.levelIndex(forSecondsPerPixel: secondsPerPixel)]
        #expect(selected.bucketDurationSec <= secondsPerPixel)
        #expect(selected.bucketDurationSec > finestDuration)
    }

    @Test("時刻 -> バケット index の逆引きが範囲外でもクランプされる")
    func bucketIndexLookupIsClamped() {
        let samples = [Float](repeating: 0, count: WaveformAnalyzer.baseFramesPerBucket * 4)
        let level = WaveformAnalyzer.analyze(samples: samples, sampleRate: 44_100).levels[0]
        #expect(level.bucketIndex(forTimeSec: -1) == 0)
        #expect(level.bucketIndex(forTimeSec: 999) == level.bucketCount - 1)
    }

}
