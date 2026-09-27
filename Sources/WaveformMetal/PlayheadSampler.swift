import Foundation

/// 古い入力時刻による表示のずれを再現するため、前回値と低頻度の取得値を保持する。
nonisolated struct PlayheadSampler {
    private var previous: Double?
    private var sampled: Double = 0
    private var sampledAt: Double = 0
    private var mode: PlayheadProjectionMode?

    /// `playheadSec` はトラックの秒数、`now` は取得間隔を測る単調増加のホスト秒数。
    /// 初回とモード変更時は現在値を採用し、以前のモードの履歴を持ち込まない。
    mutating func sample(playheadSec: Double, mode: PlayheadProjectionMode, now: Double) -> Double {
        defer { previous = playheadSec; self.mode = mode }
        if self.mode != mode || previous == nil {
            sampled = playheadSec
            sampledAt = now
            return playheadSec
        }
        switch mode {
        case .synced: return playheadSec
        case .oneFrameStale: return previous ?? playheadSec
        case .throttled20Hz:
            if now - sampledAt >= 0.05 - 1e-9 {
                sampled = playheadSec
                sampledAt = now
            }
            return sampled
        }
    }
}
