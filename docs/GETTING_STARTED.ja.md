# 導入ガイド

[English](GETTING_STARTED.md) | 日本語 · [READMEへ戻る](../README.ja.md)

[導入方法](../README.ja.md#導入)に従って、iOS 17以降のSwiftUIアプリに製品`MetalWaveformKit`を追加してください。ここでは合成データを静止表示します。音源ファイルやマイクの権限は不要です。

## 最小のビューを追加する

1. 次のコードをアプリのSwiftファイルに保存します。
2. アプリの画面から`QuickStartView()`を表示します。

このビューは1秒分のPCMを解析し、0.5秒を中心に前後0.5秒の波形を描きます。

```swift
import Metal
import SwiftUI
import MetalWaveformKit

/// Metal が使える場合に、固定の表示時刻を返す最小構成のレンダラーを作る。
/// View が保持するため、SwiftUI の再評価ごとにパイプラインを作り直す必要はない。
@MainActor
func makeWaveformRenderer(analysis: WaveformAnalysis) -> WaveformRenderer? {
    guard let device = MTLCreateSystemDefaultDevice(),
          let renderer = WaveformRenderer(device: device) else { return nil }
    renderer.analysis = analysis
    renderer.frameInputProvider = {
        WaveformFrameInput(playheadSec: 0.5, zoomScale: 16)
    }
    return renderer
}

/// 1秒分の合成波形を静止表示する、導入手順用の最小ビュー。
struct QuickStartView: View {
    @State private var renderer: WaveformRenderer?
    @State private var failed = false

    var body: some View {
        Group {
            if let renderer {
                WaveformMetalView(renderer: renderer)
                    .frame(height: 240)
            } else if failed {
                Text("Metal rendering is unavailable.")
            } else {
                ProgressView("Preparing waveform…")
            }
        }
        .task {
            guard renderer == nil, !failed else { return }
            // 解析はメインActorの外で行い、不変の結果を受け取る。
            let analysis = await Task.detached {
                let rate = 48_000.0
                let samples = (0..<48_000).map { i in
                    Float(sin(Double(i) / rate * 2 * .pi * 5) * 0.8)
                }
                return WaveformAnalyzer.analyze(samples: samples, sampleRate: rate)
            }.value
            // detached の解析が終わるまでに画面が閉じられた場合は、GPUリソースを作らない。
            guard !Task.isCancelled else { return }
            renderer = makeWaveformRenderer(analysis: analysis)
            failed = renderer == nil
        }
    }
}
```

このコードは[QuickStartView.swift](../Examples/RenderingDemo/RenderingDemo/QuickStartView.swift)と同じです。同梱プロジェクトのビルドでコンパイルを確認できます。

同梱アプリの既定の起動画面は、操作付きのRenderingDemoです。最小ビューを試すときは、`WindowGroup`の内容を`QuickStartView()`に変更します。

解析は`Task.detached`でメインActorの外で実行し、不変の解析結果を受け取ります。内部の`MTKView`はレンダラーを強参照で保持しないため、利用側で`@State`や画面モデルに保持してください。

## XcodeのCanvasでプレビューする

1. 同梱プロジェクトで`RenderingDemoApp.swift`を開きます。
2. **Editor → Canvas**を選び、Canvasを表示します。
3. プレビューを再開します。

**Rendering demo**では操作付きの画面、**Minimal integration**では導入ガイドの最小ビューを確認できます。どちらも合成データを使い、音声は出ません。

## 音声の再生位置と連動させる

音声のデコードと再生は、利用側のアプリで行います。再生位置を波形に反映するには、解析器へPCMを渡し、レンダラーを音声クロックに接続します。

### PCMデータを用意する

解析器には、次の条件を満たすデータを渡してください。

- PCMは1チャンネル分を渡します。複数チャンネルを扱う場合は、表示するチャンネルやミックス方法を利用側で決めます。
- 振幅には有限の`Float`値（通常は`-1...1`）を使います。解析器は振幅を正規化しません。
- サンプルレートには、実際の値をHz単位で渡します。有限の正の値である必要があります。

### 表示予定時刻を再生位置へ変換する

再生に合わせて波形を動かす場合は、`timedFrameInputProvider`を設定します。iOSのビューは、表示予定時刻である`CADisplayLink.targetTimestamp`を渡します。引数は`CACurrentMediaTime()`と同じ基準のホスト時刻で、単位は秒です。

この時刻は**トラック内の再生位置ではありません。** 音声クロックの再生位置へ変換し、ズーム・キュー時刻とまとめて返してください。

レンダラーは、メインActor上で1フレームに一度、どちらかの入力クロージャを呼びます。

- `timedFrameInputProvider`が設定されていれば、こちらを優先します。
- `nil`なら、従来の引数なし`frameInputProvider`を呼びます。従来の方式へ戻すときは、時刻付きのプロバイダーを`nil`にします。

通常の`draw(in:)`は、ホスト時刻に`CACurrentMediaTime()`を使います。独自の表示タイミングで描画する場合は、`draw(in:atHostTime:)`へ表示予定時刻を渡せます。

次の関数は、音声クロックの基準点から表示予定時刻の再生位置を計算します。ホスト時刻と再生位置には、**同じ瞬間を表す組**を渡してください。音声APIのホスト時刻がtick単位なら、`CACurrentMediaTime()`と同じ基準の秒へ変換します。

```swift
import QuartzCore
import MetalWaveformKit

@MainActor
func setPlaybackAnchor(
    on renderer: WaveformRenderer,
    hostTime: CFTimeInterval,
    trackSeconds: Double,
    playbackRate: Double,
    zoomScale: Double = 4
) {
    renderer.timedFrameInputProvider = { targetHostTime in
        let position = trackSeconds + (targetHostTime - hostTime) * playbackRate
        return WaveformFrameInput(playheadSec: position, zoomScale: zoomScale)
    }
}
```

### 再生位置の基準点を更新する

`playbackRate`は、ホスト時刻の1秒あたりに進むトラックの秒数です。通常再生は`1`、一時停止は`0`を渡します。音声スレッドから安全に受け渡した時刻で基準点を更新し、シーク・ループ・一時停止・速度変更の後も更新してください。

フレーム入力を更新するときは、次の条件を守ります。

- 曲の範囲やループは利用側で扱います。
- 古い再生位置と、通知がメインActorへ届いた時刻を組にしないでください。
- 音声スレッドの可変状態をメインActorから直接読むことも避けます。
- ズームやキューを操作で変える場合は、同じプロバイダー内でその時点の値をまとめて読み取ります。

### フレーム入力と設定の値

| 入力・設定 | 意味 |
| --- | --- |
| `playheadSec` | トラック先頭を0秒とした再生位置 |
| `zoomScale` | 表示幅は`16 / zoomScale`秒。付属サンプルでは1〜64 |
| `cueTimesSec` | マーカーを表示する時刻（秒）の配列 |
| `beatIntervalSec` | 一定の拍間隔。例: 120 BPMなら`0.5`秒 |

音声レンダリングの時刻と、スピーカーから実際に音が出る時刻には遅延があり得ます。このパッケージは出力遅延の測定や補正を行いません。

### レンダラーとビューの寿命を管理する

クロージャからレンダラーの所有者を参照するときは、同梱サンプルのように`[weak self]`を使い、循環参照を避けます。

音源を切り替えるときは、既存のレンダラーへ新しい`analysis`を設定します。`WaveformMetalView`はSwiftUIの更新時にレンダラーの交換も受け付けるため、ビューに新しいidentityを与える必要はありません。

iOSのビューは、ウィンドウから外れたときや非アクティブ時に表示更新を停止し、破棄時にはdisplay linkを解除します。復帰時は新しい表示予定時刻を使うため、中断中に再生が進んだかどうかは利用側の音声クロックで決まります。

画面の最大リフレッシュレートを要求しますが、実際のfpsはOSが決めます。ProMotionでも120 fpsを保証するものではありません。ライフサイクル管理と`MTKView`への直接接続は[描画の設計](DESIGN.ja.md#表示更新とビューのライフサイクルを管理する)で説明します。

## 表示できないときに確認する

| 状況 | 確認すること |
| --- | --- |
| レンダラーが`nil`になる | Metalデバイス、Metalコンパイラー、同梱シェーダーが利用できるか |
| 波形が動かない | 入力の`playheadSec`が変化しているか。最小例は静止表示 |
| 波形が表示されない | PCMが空でないか、振幅が0だけでないか、表示範囲にデータがあるか |
| macOSで`WaveformMetalView`が見つからない | このビューはiOS専用。macOSでは`WaveformRenderer`と`MTKView`を接続する |

macOSでの`MTKView`設定や描画の精度は[描画の設計](DESIGN.ja.md)、各製品の選び方は[パッケージ構成](ARCHITECTURE.ja.md)を参照してください。
