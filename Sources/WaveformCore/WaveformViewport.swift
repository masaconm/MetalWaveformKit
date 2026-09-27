//
//  WaveformViewport.swift
//
//  可視時間範囲と、トラック時刻から画面座標への変換を定義する。
//  時刻は秒、幅は drawable のピクセル数で扱う。UIKit のポイント数とは区別する。
//
//  CPU 側の投影は Double で計算し、結果を Float の NDC 座標として返す。
//  Metal 側はピクセル単位のカメラ位置と Float の fma を使うため、
//  同じ座標関係を表していても CPU / GPU の値はビット単位では一致しない。
//  通常モードの再生線は、時刻の投影とは別に画面中央へ固定する。
//

import Foundation

// MARK: - Viewport 本体

/// 「いま画面に見えている時間範囲」を表す値型。
///
/// 開始時刻と時間幅を持つ値型。トラックの範囲外も表せるため、
/// 冒頭や末尾を画面中央に置くときも、トラック長へのクランプは行わない。
public nonisolated struct WaveformViewport: Equatable, Sendable {

    /// 指定した秒数をそのまま保持する。有限な開始時刻と、有限で正の時間幅を渡す。
    public init(visibleStartSec: Double, viewportSec: Double) {
        self.visibleStartSec = visibleStartSec
        self.viewportSec = viewportSec
    }

    /// 画面左端に対応するトラック時刻（秒）
    public var visibleStartSec: Double
    /// 画面幅に収まる時間幅（秒）。ズームはこの値の逆数で表現される
    public var viewportSec: Double

    /// 画面右端に対応するトラック時刻（秒）
    public var visibleEndSec: Double { visibleStartSec + viewportSec }

    // MARK: カメラの定義

    /// 指定した再生時刻が中央に来る可視範囲を作る。
    ///
    /// 時間幅は最低 0.001 秒とする。両引数には有限値を渡す。
    /// フレーム間の差分を加算せず、その時刻から開始位置を計算するため、
    /// 差分の積み重ねによる誤差を避けられる。
    public static func centered(onPlayheadSec playheadSec: Double, viewportSec: Double) -> WaveformViewport {
        let safeViewport = max(viewportSec, 0.001)
        return WaveformViewport(
            visibleStartSec: playheadSec - safeViewport * 0.5,
            viewportSec: safeViewport
        )
    }

    /// カメラをピクセル格子にスナップする。
    ///
    /// 開始時刻を「1 drawable ピクセルに相当する秒数」の整数倍へ丸める。
    /// 固定したズーム倍率ではカメラが整数ピクセル単位で動き、
    /// サブピクセル移動による画素の明滅を抑えられる。細かな周期模様のちらつきは残り得る。
    ///
    /// 丸めによる変位は最大 0.5 ピクセル。画面中央の再生線に対し、
    /// 同じ時刻の波形側の座標がその範囲でずれるほか、浮動小数点の丸め誤差も生じる。
    /// Metal での描画には、この結果を秒から変換し直さず、専用 uniform で直接丸める。
    ///
    /// - Parameter drawableWidthPx: 描画先の有限な幅（ピクセル）。最低 1 として計算する。
    public func snappedToPixelGrid(drawableWidthPx: Double) -> WaveformViewport {
        let pixelsPerSecond = max(drawableWidthPx, 1.0) / max(viewportSec, 0.000_001)
        let snappedStart = (visibleStartSec * pixelsPerSecond).rounded() / pixelsPerSecond
        return WaveformViewport(visibleStartSec: snappedStart, viewportSec: viewportSec)
    }

    // MARK: 投影（time -> x）

    /// トラック時刻を、可視範囲を基準とする X 座標へ変換する。
    ///
    /// CPU 上の計算や入力時刻の差の検証に使う。GPU と計算精度・丸め方が異なるため、
    /// 描画された画素位置の測定には使わない。計算結果が有限値でなければ 0 を返す。
    /// - Returns: NDC（正規化デバイス座標）。左端は -1、右端は +1。範囲外は切り詰めない。
    public func ndcX(forTimeSec timeSec: Double) -> Float {
        let normalized = (timeSec - visibleStartSec) / max(viewportSec, 0.000_001)
        let ndc = Float(normalized * 2.0 - 1.0)
        // 極端な入力で非有限値になった場合も、呼び出し側へ NaN や無限大を返さない
        return ndc.isFinite ? ndc : 0
    }

    // MARK: 逆投影（x -> time）: ジェスチャ処理用

    /// NDC X 座標からトラック時刻へ戻す。
    /// 時間幅が投影側の下限値 0.000001 秒以上なら、同じ時間幅を使う逆変換になる。
    /// 入力は切り詰めず、-1...1 の外側も可視範囲外の時刻へ変換する。
    public func timeSec(forNDCX ndcX: Double) -> Double {
        visibleStartSec + ((ndcX + 1.0) * 0.5) * viewportSec
    }

    /// ビュー左端を 0、右端を 1 とした割合を、トラック時刻へ変換する。
    /// 入力の割合を 0...1 へ切り詰める処理は行わない。
    public func timeSec(atViewFraction fraction: Double) -> Double {
        visibleStartSec + fraction * viewportSec
    }

    // MARK: 解像度の指標

    /// 1 ピクセルあたりの秒数。LOD 選択とスクラブの px -> 秒変換の基準。
    public func secondsPerPixel(viewWidthPx: Double) -> Double {
        viewportSec / max(viewWidthPx, 1.0)
    }

}
