//
//  BeatQuantizerTests.swift
//  BeatGridTests
//
//  秒単位の時刻を拍へ丸める処理と、次の拍・小節境界の選択を検証する。
//

import Testing
@testable import BeatGrid

/// 1e-9の許容差は Double の計算誤差を吸収するための値。音声の出力精度は測らない。
struct BeatQuantizerTests {

    /// 128 BPM の 1 拍 = 0.46875 秒
    private let beat = 60.0 / 128.0

    @Test("拍の中間より手前は前の拍、後ろは次の拍へスナップする")
    func snapsToNearestBeat() {
        // 拍 10 の少し後 → 拍 10
        #expect(abs(BeatQuantizer.snapToNearestBeat(timeSec: beat * 10 + 0.01, beatIntervalSec: beat) - beat * 10) < 1e-9)
        // 拍 11 の少し手前 → 拍 11
        #expect(abs(BeatQuantizer.snapToNearestBeat(timeSec: beat * 11 - 0.01, beatIntervalSec: beat) - beat * 11) < 1e-9)
    }

    @Test("拍頭ちょうどの時刻は変化しない")
    func exactBeatIsUnchanged() {
        for index in [0, 1, 64, 511] {
            let time = beat * Double(index)
            #expect(abs(BeatQuantizer.snapToNearestBeat(timeSec: time, beatIntervalSec: beat) - time) < 1e-9)
        }
    }

    @Test("スナップ結果は必ず拍間隔の整数倍になる")
    func resultIsAlwaysMultipleOfBeat() {
        for raw in stride(from: 0.0, through: 30.0, by: 0.371) {
            let snapped = BeatQuantizer.snapToNearestBeat(timeSec: raw, beatIntervalSec: beat)
            let beats = snapped / beat
            #expect(abs(beats - beats.rounded()) < 1e-9)
            // 移動量は最大でも半拍
            #expect(abs(snapped - raw) <= beat / 2 + 1e-9)
        }
    }

    @Test("拍間隔が 0 以下なら入力をそのまま返す")
    func invalidIntervalReturnsInput() {
        #expect(BeatQuantizer.snapToNearestBeat(timeSec: 12.34, beatIntervalSec: 0) == 12.34)
        #expect(BeatQuantizer.snapToNearestBeat(timeSec: 12.34, beatIntervalSec: -1) == 12.34)
    }

    /// 128 BPM / 4 拍子の 1 小節 = 1.875 秒
    private var bar: Double { beat * 4 }

    @Test("小節の途中では、その小節の終わり（次の小節頭）が次境界になる")
    func nextBoundaryIsEndOfCurrentBar() {
        // 小節5の開始から1.2拍進んだ時刻では、小節6の開始を返す。
        let pressTime = bar * 5 + beat * 1.2
        let boundary = BeatQuantizer.nextBoundary(afterTimeSec: pressTime, intervalSec: bar)
        #expect(abs(boundary - bar * 6) < 1e-9)
    }

    @Test("小節頭ちょうどで押した場合はその小節を鳴らし切ってから跳ぶ")
    func nextBoundaryOnExactBarHeadIsFollowingBar() {
        // 境界上でも「現在の境界」を返さないことを確認する。再生やジャンプは呼び出し側の責務。
        let boundary = BeatQuantizer.nextBoundary(afterTimeSec: bar * 5, intervalSec: bar)
        #expect(abs(boundary - bar * 6) < 1e-9)
    }

    @Test("次境界は常に入力時刻より後で、1 小節以内にある")
    func nextBoundaryIsWithinOneBar() {
        for raw in stride(from: 0.0, through: 30.0, by: 0.313) {
            let boundary = BeatQuantizer.nextBoundary(afterTimeSec: raw, intervalSec: bar)
            #expect(boundary > raw)
            #expect(boundary - raw <= bar + 1e-9)
        }
    }
}
