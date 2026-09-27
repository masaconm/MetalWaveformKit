//
//  BeatQuantizer.swift
//
//  時刻を拍へ揃え、指定した間隔の次の境界を求める。
//  グリッドの原点はトラックの 0 秒。拍の検出や BPM 推定、再生予約は行わない。
//  ピクセルへ投影する前の秒数で計算するため、ズーム倍率は結果に影響しない。
//

import Foundation

/// 0 秒を原点とする等間隔グリッド上で時刻を計算する。状態は保持しない。
public nonisolated enum BeatQuantizer {

    /// 時刻を最も近い拍へスナップする。
    ///
    /// - Parameters:
    ///   - timeSec: スナップ対象の有限な時刻（秒）。負の時刻も扱う
    ///   - beatIntervalSec: 1 拍の長さ（秒）。有限値を渡す。0 以下なら入力をそのまま返す
    /// - Returns: 最も近い拍頭の時刻（秒）。中間点は 0 から遠い側へ丸める
    public static func snapToNearestBeat(timeSec: Double, beatIntervalSec: Double) -> Double {
        guard beatIntervalSec > 0 else { return timeSec }
        return (timeSec / beatIntervalSec).rounded() * beatIntervalSec
    }

    /// 指定時刻より後のグリッド境界を返す。
    ///
    /// 拍や小節に揃えて操作を予約するときの時刻計算に使う。予約や実行は呼び出し側で行う。
    /// 境界までの差が 1e-9 秒未満なら、その次の境界を返す。
    /// この許容差には浮動小数点の丸め誤差が含まれるため、厳密な等値判定は使わない。
    ///
    /// - Parameters:
    ///   - timeSec: 現在の有限な再生位置（秒）
    ///   - intervalSec: 有限な境界間隔（秒）。小節なら 1 拍の秒数 × 拍数。
    ///     0 以下なら入力時刻をそのまま返す
    public static func nextBoundary(afterTimeSec timeSec: Double, intervalSec: Double) -> Double {
        guard intervalSec > 0 else { return timeSec }
        let boundary = (timeSec / intervalSec).rounded(.up) * intervalSec
        // 境界上ちょうど（誤差レベル）なら次の境界へ送る
        if boundary - timeSec < 1e-9 {
            return boundary + intervalSec
        }
        return boundary
    }
}
