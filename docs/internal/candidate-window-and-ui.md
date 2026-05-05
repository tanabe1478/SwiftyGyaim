# 候補ウィンドウとUI

このドキュメントでは `CandidateWindow.swift` と `GyaimController.showWindow()` を実装寄りに読みます。IMEのUIで最も重要なのは「入力先アプリのフォーカスを奪わない」ことです。

## 1. `CandidateWindow` は `NSPanel`

```swift
class CandidateWindow: NSPanel {
    static var shared: CandidateWindow?
    ...
}
```

初期化では `.nonactivatingPanel` を指定しています。

```swift
super.init(contentRect: frame,
           styleMask: [.borderless, .nonactivatingPanel],
           backing: .buffered,
           defer: false)

becomesKeyOnlyIfNeeded = true
level = .statusBar
isOpaque = false
hasShadow = true
hidesOnDeactivate = false
```

通常の `NSWindow` やactivateするpanelを使うと、候補表示のたびに入力先アプリからフォーカスを奪う可能性があります。IMEの候補ウィンドウではこれが致命的です。

## 2. 表示モードは enum と UserDefaults

```swift
enum CandidateDisplayMode: Int {
    case list = 0
    case classic = 1

    static var current: CandidateDisplayMode {
        let raw = UserDefaults.standard.object(forKey: "candidateDisplayMode") as? Int ?? 1
        return CandidateDisplayMode(rawValue: raw) ?? .classic
    }
}
```

デフォルトは `.classic` です。表示数もenumに持たせています。

```swift
var maxVisible: Int {
    switch self {
    case .list: return 9
    case .classic: return 11
    }
}
```

この値は `GyaimController.showCands()` のページングにも使われます。UIクラスだけでなく入力フローにも影響する設定です。

## 3. view階層

`CandidateWindow` はlistとclassicの両方のviewを持ち、表示モードごとに hidden と制約を切り替えます。

```text
containerView
├─ stackView                  # list mode
├─ ClassicBackgroundView       # classic mode background
└─ classicContentView
   └─ classicScrollView
      └─ classicTextView
```

`setupListMode()` と `setupClassicMode()` は起動時に両方呼ばれます。その後 `applyDisplayMode()` で片方だけ有効化します。

```swift
NSLayoutConstraint.deactivate(listConstraints)
NSLayoutConstraint.deactivate(classicConstraints)

stackView.isHidden = !isList
classicBackgroundView?.isHidden = isList
...

if isList {
    NSLayoutConstraint.activate(listConstraints)
} else {
    NSLayoutConstraint.activate(classicConstraints)
}
```

毎回viewを作り直さず、制約セットを切り替える実装です。

## 4. list mode の実装

list mode は `NSStackView` に `NSTextField` を並べます。

```swift
private func updateListMode(_ words: [String], selectedIndex: Int, hasMore: Bool, hasPrev: Bool) {
    candidateLabels.forEach { $0.removeFromSuperview() }
    candidateLabels.removeAll()

    let count = min(words.count, CandidateDisplayMode.list.maxVisible)
    for i in 0..<count {
        let label = makeLabel(index: i, word: words[i], isSelected: i == selectedIndex)
        stackView.addArrangedSubview(label)
        candidateLabels.append(label)
    }
}
```

`makeLabel` で番号や選択ハイライトを作ります。`hasMore` がtrueなら `▼` indicatorを末尾に追加します。

## 5. classic mode の実装

classic mode はオリジナルGyaim風の吹き出し画像 `candwin.png` を背景に使います。

```swift
private var classicBackgroundView: ClassicBackgroundView?
private var classicScrollView: NSScrollView?
private var classicTextView: NSTextView?
```

候補は横並びのテキストとして `NSTextView` に入れます。背景は `ClassicBackgroundView.draw(_:)` で9-slice的に描画し、角やtailを壊さず中央を伸ばします。

classicは見た目のためにウィンドウshadowを切ります。

```swift
hasShadow = false
```

`candwin.png` 自体に影があるため、NSWindowのshadowを重ねると二重になります。

## 6. 候補ウィンドウに渡される候補は「次候補」

`GyaimController.showCands()` は、現在選択中の候補を入力先アプリの marked text に出し、候補ウィンドウにはその次から渡します。

```swift
let maxCandList = CandidateDisplayMode.current.maxVisible
var candList: [String] = []
for i in 0..<maxCandList {
    let idx = nthCand + 1 + i
    guard idx < words.count else { break }
    candList.append(words[idx])
}

candWindow?.updateCandidates(candList, selectedIndex: -1, hasMore: hasMore, hasPrev: hasPrev)
```

そのため、候補ウィンドウ内の `1` は `candidates[nthCand + 1]` に対応します。数字キー選択でも `targetIndex = nthCand + num` としているのはこのためです。

## 7. 位置計算は `CandidateWindowPositioner`

位置計算は `CandidateWindowPositioner` に集約されています。

```swift
struct CandidateWindowPositioner {
    static func resolveLineRect(...)
    static func isUsableReportedLineRect(...)
    static func calculate(...)
}
```

これはUI部品そのものから位置計算を切り出して、ユニットテストしやすくするためです。

## 8. `showWindow()` の実装

`GyaimController.showWindow()` は、まず入力先アプリからキャレット位置を取ります。

```swift
var reportedLineRect = NSRect.zero
client.attributes(forCharacterIndex: 0, lineHeightRectangle: &reportedLineRect)
```

次に、この値を検証します。

```swift
let resolution = CandidateWindowPositioner.resolveLineRect(
    reportedLineRect: reportedLineRect,
    previousValidLineRect: lastValidCandidateLineRect,
    mouseLocation: NSEvent.mouseLocation)
```

`resolution.source` は次のいずれかです。

| source | 意味 |
|---|---|
| `.reported` | IMKが返した値をそのまま使用 |
| `.previousValid` | 前回正常値へfallback |
| `.mouseLocation` | マウス位置へfallback |

`.reported` の場合だけ次回用に保存します。

```swift
if resolution.source == .reported {
    lastValidCandidateLineRect = resolution.lineRect
}
```

## 9. 不正な lineRect の判定

Webアプリでは次のような値が返ることがあります。

```text
(34.0, 10.0, 1.0, 14.0)
(60.0, 10.0, 1.0, 14.0)
```

これはスクリーン座標ではなく、入力要素内のローカル座標に見えます。実装では次の特徴を持つrectを疑わしいものとして扱います。

```swift
let looksLikeClientLocalOriginRect = lineRect.minX >= 0
    && lineRect.minY >= 0
    && lineRect.minX < 64
    && lineRect.minY < 64
    && lineRect.width <= 2
    && lineRect.height >= 8
    && lineRect.height <= 40
```

「原点付近」「caretらしい1px幅」「通常の行高程度」の組み合わせです。

## 10. スクリーン選択

位置計算に使うscreen frameは `NSScreen.main` 固定ではありません。

```swift
let screenFrame = NSScreen.screens.first { $0.frame.intersects(resolution.lineRect) }?.visibleFrame
    ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
    ?? NSScreen.main?.visibleFrame
    ?? .zero
```

優先順:

1. 解決後lineRectと交差するscreen
2. マウス位置を含むscreen
3. main screen

`visibleFrame` を使うので、メニューバーやDock領域を避けやすくなります。

## 11. `calculate()` の挙動

```swift
var y = lineRect.origin.y - winSize.height - gap

if y < screenFrame.minY {
    y = lineRect.origin.y + lineRect.height + gap
}

if y + winSize.height > screenFrame.maxY {
    y = screenFrame.maxY - winSize.height
}
if y < screenFrame.minY {
    y = screenFrame.minY
}
```

基本はカーソルの下に出します。下に収まらなければ上に出します。それでも収まらなければscreen内にclampします。

x方向も同じようにclampします。

```swift
var x = lineRect.origin.x - (mode == .list ? 5 : 0)
if x + winSize.width > screenFrame.maxX {
    x = screenFrame.maxX - winSize.width
}
if x < screenFrame.minX {
    x = screenFrame.minX
}
```

## 12. PreferencesWindow の実装

設定画面は通常の `NSWindow` です。ただしIMEは `LSBackgroundOnly` なので、表示時だけactivation policyを変えます。

```swift
static func show() {
    ...
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
}

override func close() {
    super.close()
    NSApp.setActivationPolicy(.prohibited)
}
```

UIはコードで組み立てています。各設定は対応する型のstatic setterに流れます。

例:

- 表示モード → `CandidateDisplayMode.setCurrent()`
- Google suffix → `GoogleTransliterate.setTriggerSuffix()`
- 学習設定 → `WordSearch.setStudyHiraganaEnabled()`
- 淘汰方式 → `EvictionMode.setCurrent()`

## 13. DictEditorWindow の実装

ユーザー辞書エディタは `NSTableViewDataSource` / `NSTableViewDelegate` を実装した `NSWindow` です。

内部状態:

```swift
private var entries: [(reading: String, word: String)] = []
```

保存時は `entries` から空白をtrimし、空行を除いて `WordSearch.saveDict()` に渡します。

```swift
var dict: [[String]] = []
for e in entries {
    let r = e.reading.trimmingCharacters(in: .whitespaces)
    let w = e.word.trimmingCharacters(in: .whitespaces)
    if !r.isEmpty, !w.isEmpty {
        dict.append([r, w])
    }
}
WordSearch.saveDict(dictFile: Config.localDictFile, dict: dict)
```

`WordSearch.search()` はmtimeを見てlocal辞書をreloadするので、保存後すぐに変換候補へ反映されます。
