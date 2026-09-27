//
//  WaveformAnalysis.swift
//
//  PCM の振幅を区間ごとの min/max にまとめ、描画用の解像度段階（LOD）を作る。
//  解析結果は読み取り専用の値型として、解析を行う Task から描画側へ渡せる。
//  音声ファイルの読み込みやチャンネルの合成は呼び出し側で行う。
//
//  各レベルは [min0, max0, min1, max1, ...] を保持する。
//  バケットの時刻は番号と区間幅から求めるため、時刻配列を別に持たない。
//  ズーム変更時は解析済みのレベルを選ぶ。PCM の再解析は不要。
//

import Foundation

// MARK: - LOD 1 段ぶんのエンベロープ

/// 1 つのズーム帯域に対応する min/max エンベロープ。
///
/// `minMax` はインターリーブ配列: `[min0, max0, min1, max1, ...]`
/// バケット i がカバーする時間範囲は
/// `[i * bucketDurationSec, (i+1) * bucketDurationSec)` で決まる。
/// 末尾のバケットは、元のサンプル列がある範囲だけを集計する。
/// min/max は区間内の極値を表し、極値が現れた正確な時刻は保持しない。
public nonisolated struct WaveformLODLevel: Sendable {

    /// 1 バケットがカバーする秒数
    public let bucketDurationSec: Double

    /// `[min0, max0, min1, max1, ...]` のインターリーブ配列
    public let minMax: [Float]

    /// バケット数（= minMax.count / 2）
    public var bucketCount: Int { minMax.count / 2 }

    /// 時刻からバケット番号を O(1) で求め、範囲外なら端へ揃える。
    ///
    /// バケットが空の場合は 0 を返すため、配列へのアクセス前に要素数を確認する。
    /// `timeSec / bucketDurationSec` は、Int に変換できる有限値であること。
    public func bucketIndex(forTimeSec timeSec: Double) -> Int {
        guard bucketDurationSec > 0 else { return 0 }
        let index = Int(timeSec / bucketDurationSec)
        // 範囲外の時刻（トラック外へのスクロール等）は端のバケットへクランプ
        return min(max(index, 0), max(bucketCount - 1, 0))
    }
}

// MARK: - トラック 1 本ぶんの解析結果

/// トラック 1 本ぶんの解析結果。ロード時に構築したら以降は読み取り専用。
///
/// levels は index 0 が最も細かく、以降 2 倍ずつ粗くなるピラミッド構造。
/// 粗いレベルは隣接バケットの極値をまとめたもので、元の PCM は保持しない。
public nonisolated struct WaveformAnalysis: Sendable {

    /// トラック全長（秒）
    public let durationSec: Double
    /// 解析元のサンプルレート（Hz）
    public let sampleRate: Double
    /// LOD ピラミッド。index 0 が最も細かいレベル
    public let levels: [WaveformLODLevel]

    /// 現在のズームに合う LOD を選ぶ。
    ///
    /// 方針: 「バケット幅が secondsPerPixel を超えない範囲で、最も粗いレベル」。
    /// 該当するレベルがない場合は 0 を返す。空の `levels` へのアクセスは呼び出し側で避ける。
    /// `secondsPerPixel` の単位は秒 / drawable ピクセル。描画側では目標の
    /// バケット密度を保つため、この値をオーバーサンプリング係数で割って渡す。
    public func levelIndex(forSecondsPerPixel secondsPerPixel: Double) -> Int {
        var selected = 0
        for (index, level) in levels.enumerated() where level.bucketDurationSec <= secondsPerPixel {
            selected = index
        }
        return selected
    }
}

// MARK: - 解析器

/// PCM サンプル列 -> LOD ピラミッドの変換を行う名前空間。
/// 状態を持たない純関数の集まりなので enum（インスタンス化不可）にしている。
public nonisolated enum WaveformAnalyzer {

    /// 最細レベルの 1 バケットあたりサンプル数。
    /// 44.1 kHz では約 0.73 ms。これより細かい時間の形状は復元しない。
    public static let baseFramesPerBucket = 32

    /// これ以下のバケット数になったら粗いレベルの生成を打ち切る。
    /// 最後のレベルは 512 以下になる。描画幅に応じた生成上限ではない。
    public static let minimumBucketCount = 512

    /// PCM サンプル列から全 LOD レベルを構築する。
    ///
    /// 同期処理で、計算量は O(サンプル数)。長い入力はメインスレッドの外で解析する。
    /// 空の入力、または 0 以下のサンプルレートには、空の解析結果を返す。
    ///
    /// - Parameters:
    ///   - samples: 1 チャンネル分の有限な振幅値。描画は通常 -1...1 を想定する。
    ///     チャンネルの合成や振幅の正規化は行わない。
    ///   - sampleRate: 入力のサンプルレート（Hz）。通常は有限な正の値を渡す。
    /// - Returns: 各区間の min/max と LOD。元のサンプル列は結果に保持しない。
    public static func analyze(samples: [Float], sampleRate: Double) -> WaveformAnalysis {
        guard !samples.isEmpty, sampleRate > 0 else {
            return WaveformAnalysis(durationSec: 0, sampleRate: sampleRate, levels: [])
        }

        // 最細レベルを PCM から直接作り、以降は 1 つ前のレベルを
        // 2 バケットずつ畳んで作る（PCM を何度も走査しない）
        var levels: [WaveformLODLevel] = []
        levels.append(makeBaseLevel(samples: samples, sampleRate: sampleRate))

        while let last = levels.last, last.bucketCount > minimumBucketCount {
            levels.append(makeCoarserLevel(from: last))
        }

        return WaveformAnalysis(
            durationSec: Double(samples.count) / sampleRate,
            sampleRate: sampleRate,
            levels: levels
        )
    }

    /// 最細レベル: PCM を baseFramesPerBucket サンプルずつ min/max に畳む。
    private static func makeBaseLevel(samples: [Float], sampleRate: Double) -> WaveformLODLevel {
        let framesPerBucket = baseFramesPerBucket
        let bucketCount = (samples.count + framesPerBucket - 1) / framesPerBucket
        var minMax = [Float](repeating: 0, count: bucketCount * 2)

        // サンプル列の連続した領域を直接走査する。末尾の端数は実在するサンプルだけで集計する。
        samples.withUnsafeBufferPointer { buffer in
            for bucket in 0..<bucketCount {
                let start = bucket * framesPerBucket
                let end = min(start + framesPerBucket, buffer.count)
                var lo = buffer[start]
                var hi = buffer[start]
                for frame in (start + 1)..<end {
                    let value = buffer[frame]
                    if value < lo { lo = value }
                    if value > hi { hi = value }
                }
                minMax[bucket * 2] = lo
                minMax[bucket * 2 + 1] = hi
            }
        }

        return WaveformLODLevel(
            bucketDurationSec: Double(framesPerBucket) / sampleRate,
            minMax: minMax
        )
    }

    /// 粗いレベル: 隣接 2 バケットを 1 つに畳む（min は min 同士、max は max 同士）。
    /// 各区間の振幅の極値を保持する。ピークの正確な時刻や元の波形形状は復元しない。
    private static func makeCoarserLevel(from level: WaveformLODLevel) -> WaveformLODLevel {
        let sourceCount = level.bucketCount
        let bucketCount = (sourceCount + 1) / 2
        var minMax = [Float](repeating: 0, count: bucketCount * 2)

        level.minMax.withUnsafeBufferPointer { source in
            for bucket in 0..<bucketCount {
                let first = bucket * 2
                // バケット数が奇数のときは最後のバケットを単独で引き継ぐ
                let second = min(first + 1, sourceCount - 1)
                minMax[bucket * 2] = min(source[first * 2], source[second * 2])
                minMax[bucket * 2 + 1] = max(source[first * 2 + 1], source[second * 2 + 1])
            }
        }

        return WaveformLODLevel(
            bucketDurationSec: level.bucketDurationSec * 2,
            minMax: minMax
        )
    }
}
