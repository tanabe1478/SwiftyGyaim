# 入力・変換・確定フロー

このファイルでは、`GyaimController.swift` の実装を中心に、キー入力1回がどのように状態を変え、候補検索・marked text・確定に進むかを追います。

## 1. 状態は `GyaimController` に集約されている

`GyaimController` の入力状態は、ほぼ次の4変数で説明できます。

```swift
private var inputPat = ""
private var candidates: [SearchCandidate] = []
private var nthCand = 0
private var searchMode = 0

private var converting: Bool {
    !inputPat.isEmpty
}
```

- `inputPat`: ユーザーが打ったローマ字列
- `candidates`: 現在の候補全体
- `nthCand`: `candidates` のうち marked text として出している候補
- `searchMode`: `0=prefix`, `1=exact`, `2=Google`

ポイントは、未確定文字列を「かな」ではなく「ローマ字」で持つことです。`nihon` と打っている時、`inputPat` は `"nihon"` のままで、表示やfallbackのタイミングで `RomaKana` を使います。

## 2. `handle(_:client:)` の実装上の読み方

`handle(_:client:)` は長いですが、上から順番に優先度の高いものを処理しているだけです。

```swift
override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard event.type == .keyDown else { return false }
    ...
}
```

戻り値は「IMEがこのイベントを消費したか」です。`true` なら入力先アプリには渡りません。

### 2.1 JISかな/英数キー

```swift
if keyCode == kVirtualJISKanaModeKey || keyCode == kVirtualJISRomanModeKey {
    return true
}
```

JISキーボードのかな/英数キーは、IME切替に絡むキーなのでここでは消費します。

### 2.2 変換中ショートカット

```swift
if converting, KeyBindings.shared.matchesHiragana(event: event) {
    fixAsKana(hiragana: true, client: sender)
    return true
}
```

`converting` 中だけ有効です。通常入力より先に見ることで、例えば `Ctrl+G` を文字入力ではなくGoogle変換として扱えます。

判定される順番:

1. ひらがな確定
2. カタカナ確定
3. Google変換
4. 候補削除

### 2.3 `event.characters` の取得

```swift
guard let eventString = event.characters, !eventString.isEmpty else { return true }
guard let c = eventString.utf8.first else { return true }
```

SwiftyGyaim の通常入力処理はASCII前提なので、分岐は `UInt8` の `c` で行います。日本語そのもののキー入力をここで受ける設計ではありません。

## 3. 分岐ごとの副作用

### Backspace / Escape

```swift
if c == 0x08 || c == 0x7f || c == 0x1b {
    if !bsThrough, converting {
        if nthCand > 0 {
            nthCand -= 1
            showCands(client: sender)
        } else {
            inputPat = String(inputPat.dropLast())
            searchAndShowCands(client: sender)
        }
        handled = true
    }
}
```

候補選択中なら候補を戻し、そうでなければ `inputPat` の末尾を削ります。削った結果に対して再検索するため、Backspaceでも `searchAndShowCands()` が呼ばれます。

`tmpImageDisplayed` / `bsThrough` は画像候補貼り付け時の特殊処理です。画像を一度仮貼りした後のBackspaceをIME側でどう扱うかを制御します。

### Space

```swift
else if c == 0x20 {
    if converting {
        if nthCand < candidates.count - 1 {
            nthCand += 1
            showCands(client: sender)
        }
        handled = true
    }
}
```

Space は候補を進めます。`nthCand` を1つ進めて `showCands()` を呼ぶだけです。検索自体はしません。

### Enter

```swift
else if c == 0x0a || c == 0x0d {
    if converting {
        if searchMode > 0 {
            fix(client: sender)
        } else {
            if nthCand == 0 {
                searchMode = 1
                searchAndShowCands(client: sender)
            } else {
                fix(client: sender)
            }
        }
        handled = true
    }
}
```

ここがGyaimらしい挙動です。

- prefix mode (`searchMode == 0`) かつ `nthCand == 0` のEnterは、即確定ではなく exact search に遷移します
- すでに候補を選んでいる、または exact/Google mode なら確定します

つまり最初のEnterは「変換」、次のEnterは「確定」に近い振る舞いになります。

### 数字キー

```swift
else if converting, nthCand > 0 || searchMode > 0,
        c >= 0x31, c <= 0x39 {
    let num = Int(c - 0x30)
    let targetIndex = nthCand + num
    if targetIndex < candidates.count {
        nthCand = targetIndex
        fix(client: sender)
    }
}
```

候補ウィンドウに見えている1〜9番の候補を選択します。`targetIndex = nthCand + num` なのは、候補ウィンドウが `nthCand + 1` 以降を表示しているためです。

### 通常文字

```swift
else if c >= 0x21, c <= 0x7e,
        modifierFlags.isDisjoint(with: [.control, .command, .option]) {
    if nthCand > 0 || searchMode > 0 {
        fix(client: sender)
    }
    if inputPat.isEmpty {
        captureExternalCandidates(client: sender)
    }
    inputPat += eventString
    searchAndShowCands(client: sender)
    searchMode = 0
    handled = true
}
```

候補選択中に通常文字を打つと、まず現在候補を確定してから新しい入力を始めます。これは「変換中に次の単語を打ち始めたら前の単語を確定する」というIMEの自然な挙動です。

入力開始時だけ `captureExternalCandidates()` を呼ぶ点も重要です。クリップボードや選択テキスト候補は、入力途中で毎回取り直すのではなく「最初のキー入力時点」の文脈として固定します。

## 4. `searchAndShowCands()` の詳細

```swift
private func searchAndShowCands(client sender: Any?) {
    guard let ws else { return }

    if GoogleTransliterate.hasTriggerSuffix(inputPat) {
        let query = GoogleTransliterate.stripTriggerSuffix(inputPat)
        triggerGoogleTransliterate(query: query, client: sender)
        return
    }

    if searchMode == 1 {
        ... exact search ...
    } else {
        ... prefix search ...
    }

    nthCand = 0
    showCands(client: sender)
}
```

### Google suffix が最優先

辞書検索より先に `GoogleTransliterate.hasTriggerSuffix()` を見ます。suffixが付いていたら通常検索はせず、非同期Google変換に移ります。

### exact search

```swift
candidates = ws.search(query: inputPat, searchMode: searchMode)
let katakana = rk.roma2katakana(inputPat)
candidates.insert(SearchCandidate(word: katakana), at: 0)
let hiragana = rk.roma2hiragana(inputPat)
candidates.insert(SearchCandidate(word: hiragana), at: 0)
```

完全一致モードでは、辞書候補に加えてかな候補を先頭に置きます。`filter` で同じwordを除外してから `insert` するので、重複してもかな候補が前に来ます。

### prefix search

```swift
let searchResults = ws.search(query: inputPat, searchMode: searchMode)
let hiragana = rk.roma2hiragana(inputPat)
candidates = Self.buildPrefixCandidates(...)
```

`buildPrefixCandidates()` はテスト可能なstatic関数に切り出されています。

```swift
candidates.insert(SearchCandidate(word: inputPat), at: 0)
if candidates.count < CandidateDisplayMode.current.maxVisible, !hiragana.isEmpty {
    candidates.append(SearchCandidate(word: hiragana))
}
```

prefix中は `inputPat` 自体を第0候補にします。これにより、未変換のローマ字をそのまま確定する経路が残ります。

## 5. `showCands()` の詳細

`showCands()` は名前以上に重要で、入力先アプリへの marked text 更新もここで行います。

```swift
let words = candidates.map(\.word)
guard nthCand < words.count, let word = words[safe: nthCand] else { return }
guard let client = sender as? IMKTextInput else { return }
```

### marked text

```swift
let attrStr = NSAttributedString(string: word, attributes: attrs)
client.setMarkedText(attrStr,
    selectionRange: NSRange(location: word.count, length: 0),
    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
```

ここで入力先アプリ上の未確定テキストが更新されます。候補選択で `nthCand` が変わるたびに、marked text も候補語に変わります。

### 候補ウィンドウ

```swift
for i in 0..<maxCandList {
    let idx = nthCand + 1 + i
    guard idx < words.count else { break }
    candList.append(words[idx])
}
```

候補ウィンドウには「現在marked textに出ている候補の次」から渡します。なので `selectedIndex` は現在 `-1` です。

## 6. 確定処理 `fix()`

```swift
private func fix(client sender: Any? = nil, skipStudy: Bool = false) {
    guard nthCand < candidates.count else {
        resetState()
        return
    }
    let candidate = candidates[nthCand]
    let word = candidate.word
    let reading = candidate.reading ?? inputPat
```

`reading` は候補が持っていればそれを使い、なければ現在の `inputPat` を使います。外部候補やsynthetic候補では `reading == nil` があり得るためです。

クライアント取得は必ずfallbackします。

```swift
let resolvedClient = (sender as? IMKTextInput) ?? (self.client() as? IMKTextInput)
```

`sender` だけに頼ると、deactivation時にテキストを失うことがあります。

### 学習と登録

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

外部候補は学習辞書ではなくlocal辞書へ登録します。通常候補はstudy辞書に入ります。`ds` はタイムスタンプなので学習しません。

## 7. `routeEvent()` は何のためにあるか

`routeEvent()` は `handle()` の分岐ロジックをテストするための純粋関数です。

```swift
static func routeEvent(...) -> HandleResult
```

戻り値は副作用ではなく `HandleAction` です。

```swift
enum HandleAction: Equatable {
    case searchAndShow
    case showCands
    case fix
    case fixAsKana(hiragana: Bool)
    case googleTransliterate
    case deleteCandidate
    ...
}
```

`handle()` は実際に `setMarkedText` や `insertText` を呼ぶため、テストが難しくなります。そこで分岐条件だけを `routeEvent()` に寄せ、`HandleEventTests` で網羅しています。

ただし、`handle()` と `routeEvent()` は完全に同じ実装ではありません。`routeEvent()` は「分岐の契約」をテストするためのモデルです。副作用や実際のUI更新は `handle()` 側を読む必要があります。
