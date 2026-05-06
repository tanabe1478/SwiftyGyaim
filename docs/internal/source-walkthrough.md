# ソースコードを読む: 実装ウォークスルー

このドキュメントは、SwiftyGyaim の実装を「上から順に読む」ためのガイドです。Swift の文法や Cocoa/AppKit の基礎は知っている前提で、IME固有のAPIと、このリポジトリでの具体的な実装判断に踏み込みます。

## 1. エントリポイント: `main.swift`

SwiftyGyaim のプロセスは通常の Cocoa app と同じく `NSApplication` を回しますが、IMEとして重要なのは `IMKServer` を作る点です。

```swift
let server = IMKServer(name: "Gyaim_Connection",
                       bundleIdentifier: Bundle.main.bundleIdentifier!)

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
```

ここでの `server` 変数は使われていないように見えますが、生成して生存させること自体が目的です。`IMKServer` は `Resources/Info.plist` の `InputMethodConnectionName` と同じ名前で作られ、macOS の入力ソース機構から接続されます。

ポイントは次の2つです。

- `IMKServer(name:)` の `name` と `Info.plist` の接続名が一致していること
- `NSApplication.shared.run()` に入る前に server を作っていること

`server` をローカル変数にしているのは少し不安に見えますが、トップレベルコードなのでプロセス生存中に保持されます。

## 2. アプリ起動後: `AppDelegate`

`AppDelegate.applicationDidFinishLaunching` は、IMEとしての最小限の初期化を行います。

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    Config.setup()
    Log.config.info("Gyaim launched")

    clipboardTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
        CopyText.set(NSPasteboard.general.string(forType: .string))
    }
}
```

`Config.setup()` は `~/.gyaim/` などのユーザーデータ置き場を整えます。クリップボードは後述の `ClipboardMonitor` でも監視しますが、ここではバックアップ的に60秒周期で `CopyText` に保存しています。

終了時は次の処理です。

```swift
func applicationWillTerminate(_ notification: Notification) {
    GyaimController.saveStudyDictIfNeeded()
    FileLogger.shared.flush()
    clipboardTimer?.invalidate()
}
```

`WordSearch.study()` は現在、学習ごとに即時保存します。それでも `applicationWillTerminate` に保存処理を残しているのは、IMEプロセスのライフサイクルは通常アプリより読みにくく、終了時のセーフティネットを置く価値があるためです。

## 3. IME本体: `GyaimController`

`GyaimController` は `IMKInputController` のサブクラスです。macOSから見ると、このクラスが「入力メソッドのcontroller」です。

```swift
@objc(GyaimController)
class GyaimController: IMKInputController {
    private static var shared: GyaimController?

    private var inputPat = ""
    private var candidates: [SearchCandidate] = []
    private var nthCand = 0
    private var searchMode = 0
    ...
}
```

`@objc(GyaimController)` が重要です。`Info.plist` の `InputMethodServerControllerClass` から Objective-C runtime 経由で参照されるため、Swift側の型名を明示しています。

### `init(server:delegate:client:)`

```swift
override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
    super.init(server: server, delegate: delegate, client: inputClient)

    if candWindow == nil {
        candWindow = CandidateWindow()
    }

    if ws == nil {
        if let dictPath = Bundle.main.path(forResource: "dict", ofType: "txt") {
            ws = WordSearch(connectionDictFile: dictPath,
                            localDictFile: Config.localDictFile,
                            studyDictFile: Config.studyDictFile)
        }
    }

    resetState()
    GyaimController.shared = self
}
```

ここで辞書をロードし、候補ウィンドウを作ります。`GyaimController.shared` は Google変換の非同期callbackなど、controllerインスタンスに戻って候補表示を更新したい箇所で使います。

InputMethodKit ではクライアントアプリごとにcontrollerが作られることがあるため、`shared` を安易に万能singletonとして扱うのは危険です。この実装では「現在最後に作られたcontrollerへ非同期候補を返す」用途に限定しています。

## 4. 変換状態の持ち方

SwiftyGyaim は、未確定入力をローマ字の `inputPat` として保持します。

```swift
private var inputPat = ""
private var candidates: [SearchCandidate] = []
private var nthCand = 0
private var searchMode = 0

private var converting: Bool {
    !inputPat.isEmpty
}
```

つまり `にほん` と入力中に見えていても、内部状態は `nihon` です。画面に出す未確定テキストやfallback候補は `RomaKana` で都度変換します。

この方式の利点は、辞書のreadingもローマ字で統一できることです。一方で、かな入力そのものを主状態にするIMEとは設計が違うので、`inputPat` と表示文字列のズレに注意が必要です。

## 5. キー入力: `handle(_:client:)`

キー入力はすべてここに来ます。

```swift
override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard event.type == .keyDown else { return false }
    ...
}
```

戻り値は「このイベントをIMEが処理したか」です。`true` を返すと入力先アプリには渡りません。`false` だと通常キーとしてアプリに渡ります。

処理の並びは実装上かなり重要です。

1. JISかな/英数キーを消費
2. 変換中ショートカットを判定
3. `event.characters` を読む
4. 単キーショートカットを判定
5. Backspace / Space / Enter / 数字キー / 通常文字を処理

例えば `;` は通常なら入力文字ですが、変換中ならひらがな確定です。そのため通常文字追加より前に単キー確定を判定しています。

## 6. 候補検索: `searchAndShowCands()`

通常文字が入力されると、最後にここへ来ます。

```swift
inputPat += eventString
searchAndShowCands(client: sender)
searchMode = 0
```

`searchAndShowCands()` は `searchMode` によって候補構成を変えます。

### prefix mode

```swift
let searchResults = ws.search(query: inputPat, searchMode: searchMode)
let hiragana = rk.roma2hiragana(inputPat)
candidates = Self.buildPrefixCandidates(
    searchResults: searchResults,
    inputPat: inputPat,
    clipboardCandidate: clipboardCandidate,
    selectedCandidate: selectedCandidate,
    hiragana: hiragana
)
```

prefix mode では、辞書候補に加えて以下を前後に差し込みます。

- `inputPat` そのもの
- クリップボード候補
- 選択テキスト候補
- 候補が少ない場合のひらがなfallback

これらは辞書由来ではないので `CandidateSource.synthetic` や `.external` になります。

### exact mode

Enter時に `nthCand == 0` なら `searchMode = 1` にして完全一致検索します。

```swift
if searchMode == 1 {
    candidates = ws.search(query: inputPat, searchMode: searchMode)
    let katakana = rk.roma2katakana(inputPat)
    candidates.insert(SearchCandidate(word: katakana), at: 0)
    let hiragana = rk.roma2hiragana(inputPat)
    candidates.insert(SearchCandidate(word: hiragana), at: 0)
}
```

完全一致検索では、ひらがな/カタカナ候補を先頭に入れます。このモードは「明示的に変換しようとしている」状態なので、prefix modeよりも確定候補としてのかなを強く出します。

## 7. 候補表示: `showCands()`

`showCands()` は2つのことをします。

1. 現在選択中の候補を marked text として入力先に表示
2. 次候補のリストを `CandidateWindow` に渡す

```swift
let words = candidates.map(\.word)
guard nthCand < words.count, let word = words[safe: nthCand] else { return }
```

選択中候補は `nthCand` です。候補ウィンドウに出す一覧は `nthCand + 1` から始まります。

```swift
for i in 0..<maxCandList {
    let idx = nthCand + 1 + i
    guard idx < words.count else { break }
    candList.append(words[idx])
}
```

この設計では「今marked textに出ている候補」と「候補ウィンドウに並ぶ次候補」が分かれます。

marked text は次のように設定します。

```swift
let attrStr = NSAttributedString(string: word, attributes: attrs)
client.setMarkedText(attrStr,
    selectionRange: NSRange(location: word.count, length: 0),
    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
```

`replacementRange` に `NSNotFound` を使うのは、現在のmarked textをIME側で置き換える一般的な使い方です。

## 8. 確定: `fix()`

確定処理は `fix(client:skipStudy:)` です。

```swift
let candidate = candidates[nthCand]
let word = candidate.word
let reading = candidate.reading ?? inputPat
...
client.insertText(word, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
```

その後、学習や登録を行います。

```swift
if skipStudy {
    ...
} else {
    let isExternalCandidate = (word == clipboardCandidate || word == selectedCandidate)
    if isExternalCandidate {
        ws?.register(word: word, reading: inputPat)
    } else if let reading = candidate.reading {
        ws?.study(word: word, reading: reading)
    } else {
        ws?.study(word: word, reading: inputPat)
    }
}
```

外部候補を確定した場合は、学習辞書ではなくユーザー辞書に登録します。これは「ユーザーがクリップボードや選択テキストから候補として明示的に選んだ語」は今後も出したい可能性が高い、という設計です。

IME切替時の自動確定では `skipStudy: true` です。ユーザーが候補を選んだわけではないので学習しません。

## 9. ウィンドウ位置: `showWindow()`

候補ウィンドウ表示は、marked text更新とは別に `showWindow()` で行います。

```swift
var reportedLineRect = NSRect.zero
client.attributes(forCharacterIndex: 0, lineHeightRectangle: &reportedLineRect)
```

この値は理想的にはスクリーン座標のキャレット行矩形です。しかし、Webアプリなどではローカル座標が返ることがあります。

そこで次の解決処理を挟みます。

```swift
let resolution = CandidateWindowPositioner.resolveLineRect(
    reportedLineRect: reportedLineRect,
    previousValidLineRect: lastValidCandidateLineRect,
    mouseLocation: NSEvent.mouseLocation)
```

`resolution.source` が `.reported` なら、次回fallback用に `lastValidCandidateLineRect` へ保存します。

位置計算は `CandidateWindowPositioner.calculate()` に分けられています。これはAppKitに依存しすぎない純粋関数に近く、テストしやすくするためです。

## 10. まとめ: SwiftyGyaimらしい実装ポイント

SwiftyGyaim の実装は、複雑な形態素解析エンジンというより、「InputMethodKitの制約の中で、ローマ字入力・辞書検索・候補UIを小さくつなぐ」設計です。

読解時の重要ポイントは次です。

- 主状態は `inputPat` というローマ字文字列
- 候補は `SearchCandidate` と `CandidateSource` で出自を持つ
- `GyaimController` が入力状態・辞書・UIを束ねる
- `WordSearch` は Study / Local / Connection の3層を統合する
- 候補ウィンドウは `NSPanel.nonactivatingPanel` でフォーカスを奪わない
- InputMethodKit の `sender` や `lineRect` は信用しすぎない
- 学習辞書は複数controllerインスタンスを考えて static 共有する
