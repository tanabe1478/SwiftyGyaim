# 候補ウィンドウとUI

## 中心ファイル

- `CandidateWindow.swift`
- `GyaimController.swift`
- `PreferencesWindow.swift`
- `DictEditorWindow.swift`

## CandidateWindow の役割

`CandidateWindow` は変換候補を表示する `NSPanel` です。

重要な設定:

```swift
styleMask: [.borderless, .nonactivatingPanel]
level = .statusBar
backgroundColor = .clear
isOpaque = false
```

`.nonactivatingPanel` により、入力先アプリのフォーカスを奪わずに候補を表示できます。

## 表示モード

`CandidateDisplayMode` は2種類です。

| モード | 値 | 表示数 | 見た目 |
|---|---:|---:|---|
| `.list` | 0 | 9 | 縦リスト、番号付き、ハイライト行 |
| `.classic` | 1 | 11 | オリジナルGyaim風、`candwin.png` 背景、横並び |

現在の設定は `UserDefaults` の `candidateDisplayMode` から読みます。デフォルトは `.classic` です。

## view構成

```text
CandidateWindow(NSPanel)
└─ containerView
   ├─ list mode
   │  └─ NSStackView
   │     └─ NSTextField labels
   │
   └─ classic mode
      ├─ ClassicBackgroundView
      └─ classicContentView
         └─ NSScrollView
            └─ NSTextView
```

`applyDisplayMode()` でlist用制約とclassic用制約を切り替えます。

## 候補更新

`GyaimController.showCands()` が表示対象候補をページングし、`CandidateWindow.updateCandidates()` に渡します。

```swift
func updateCandidates(_ words: [String], selectedIndex: Int,
                      hasMore: Bool = false, hasPrev: Bool = false)
```

`hasMore` がtrueなら、末尾に `▼` を表示します。

- list: indicator labelを追加
- classic: テキスト末尾に `▼`

`hasPrev` は将来拡張用で、現在のUIでは表示に使いません。

## ページング

`nthCand` は全候補配列上の選択位置です。候補ウィンドウには `nthCand + 1` から最大表示数ぶんの候補を渡します。

```text
candidates: [0, 1, 2, 3, 4, ...]
selected nthCand = 3
window receives candidates[4..<4+maxVisible]
```

この設計では、0番目候補を「入力そのもの」や補助候補として扱いつつ、スペースで次候補へ進む動きになります。

## 位置計算

位置計算は `CandidateWindowPositioner` に分離され、ユニットテスト可能です。

主な関数:

| 関数 | 役割 |
|---|---|
| `resolveLineRect()` | IMKが返したlineRectの妥当性検証とfallback |
| `isUsableReportedLineRect()` | 原点付近の怪しいrectを検出 |
| `calculate()` | rect, window size, screen frameから表示originを計算 |

### 位置決定の流れ

```text
GyaimController.showWindow()
  │
  ├─ client.attributes(... lineHeightRectangle: &reportedLineRect)
  │
  ├─ CandidateWindowPositioner.resolveLineRect()
  │   ├─ 正常なら reportedLineRect
  │   ├─ 不正なら lastValidCandidateLineRect
  │   └─ それも無ければ NSEvent.mouseLocation
  │
  ├─ 対象スクリーンの visibleFrame を決定
  │
  ├─ CandidateWindowPositioner.calculate()
  │   ├─ 基本はカーソル下
  │   ├─ 下に収まらなければ上へflip
  │   └─ visibleFrame内にclamp
  │
  └─ cw.setFrameOrigin(origin)
```

### lineRect fallback

一部のブラウザ/Webアプリでは、`attributes(forCharacterIndex:lineHeightRectangle:)` がスクリーン座標ではなくビュー原点付近のローカル座標を返します。

観測例:

```text
(34.0, 10.0, 1.0, 14.0)
(60.0, 10.0, 1.0, 14.0)
```

この値をそのまま使うと候補ウィンドウが画面左下付近に表示されます。現在は「原点付近・1px幅・通常行高程度」を疑わしいrectとして扱います。

## Mozc実装との対応

Mozc の候補ウィンドウ位置決定も、preedit rect / target point と対象モニタの working area を使います。

- 下に収まらなければ上へ逃がす
- それでも収まらなければworking area内にクランプ
- 対象displayを選ぶ

SwiftyGyaim も `NSScreen.visibleFrame` を使って同様にクランプします。ただし IMKクライアントがローカル座標を返す問題があるため、Mozcより一段前で `lineRect` 検証を追加しています。

## PreferencesWindow

`PreferencesWindow` は設定画面です。

設定項目:

| セクション | 内容 |
|---|---|
| キーボードショートカット | ひらがな/カタカナ確定、Google変換、候補削除 |
| 候補 | 表示スタイル、クリップボード候補、選択テキスト候補 |
| 学習辞書 | 淘汰方式、平仮名学習、完全一致reading優先 |
| Google変換 | トリガー文字、ショートカット |
| ログ | ログ有効化、削除、Finder表示 |

`PreferencesWindow.show()` では `.accessory` に切り替えて前面表示し、`close()` で `.prohibited` に戻します。

## DictEditorWindow

`DictEditorWindow` は `~/.gyaim/localdict.txt` の編集UIです。

- `NSTableView` で reading / word を編集
- 追加・削除・保存・再読込ボタン
- 保存時は `WordSearch.saveDict()` を使う
- `WordSearch.search()` はmtime hot reloadするため、保存後は変換候補に反映されます

## UI実装の注意点

- 候補ウィンドウはフォーカスを奪わないことが最優先
- 設定系ウィンドウだけ activation policy を切り替える
- 候補表示モード切替では制約のactivate/deactivateを正しく行う
- 候補ウィンドウ位置は `NSScreen.main` 固定ではなく、対象rect/マウス位置のスクリーンを使う
- `lineRect` は取得できても正しいとは限らない
