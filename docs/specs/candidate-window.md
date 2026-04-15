# Spec: 候補ウィンドウ

> Trigger: CandidateWindow.swift, PreferencesWindow.swift
> Last updated: 2026-04-15 (完全一致reading優先トグル追加 ADR-016/017)

## 概要

NSPanelベースの非アクティブウィンドウ。フォーカスを奪わない（`.nonactivatingPanel`）。

## 表示モード

| モード | 1ページ表示数 | レイアウト | 選択表示 |
|--------|-------------|----------|---------|
| list | 9 | 縦リスト、番号1-9（10番目以降は番号なし） | ハイライト行 |
| classic | 11 | 横並び、candwin.png背景 | 下線 |

UserDefaultsキー: `candidateDisplayMode` (Int, 0=list, 1=classic, デフォルト1)

## ページ送り

候補が1ページの表示数を超える場合、スペースキーで`nthCand`を進めると表示がスクロールする。`showCands()`が`nthCand+1`から`maxVisible`個を表示ウィンドウに渡す。

### ページインジケータ（▼）

続きの候補がある場合（`hasMore=true`）のみ、末尾に▼を表示:
- **リスト表示**: stackViewの最下部にインジケータラベル（薄い色、中央揃え）
- **クラシック表示**: テキスト末尾に` ▼`を付加

`updateCandidates(_:selectedIndex:hasMore:hasPrev:)` で制御。`hasPrev` は現在UI表示には使用しない（将来拡張用）。

## Classic背景の描画

`ClassicBackgroundView`: candwin.pngを9スライス描画（上部/中央/下部をストレッチ）。候補数に応じて幅を可変。

## 位置計算

`CandidateWindowPositioner`: クライアントから取得した`lineRect`（カーソル位置）を基準に表示位置を計算。画面境界でクランプ。

## モード切替の実装

NSLayoutConstraintのactivation/deactivationで切り替え。list用のNSStackViewとclassic用のClassicBackgroundViewを両方保持し、表示時に切り替える。

## PreferencesWindow: 学習辞書セクション

候補セクションの下に「学習辞書」セクションを追加（ADR-014）。

- **淘汰方式**: NSSegmentedControl（3セグメント: MRU / 淘汰なし / スコアベース）
- UserDefaultsキー: `studyDictEvictionMode` (Int, 0=mru, 1=none, 2=scoreBased, デフォルト0)
- `changeEvictionMode(_:)` アクションで即座にUserDefaultsに保存
- `buildUI()` と `rebuildLayout()` の両方に同じUIを構築（既存パターンに従う）
- **平仮名学習**: チェックボックス「平仮名の確定を学習する」（デフォルトON）
- UserDefaultsキー: `studyHiraganaEnabled` (Bool, デフォルトtrue)
- `toggleStudyHiragana(_:)` アクションで即座にUserDefaultsに保存
- **完全一致reading優先**: チェックボックス「完全一致の読みを優先する」（デフォルトOFF、ADR-016/017）
- UserDefaultsキー: `exactReadingMatchPriority` (Bool, デフォルトfalse)
- `toggleExactReadingMatchPriority(_:)` アクションで即座にUserDefaultsに保存
- ON時は前方一致検索 (searchMode==0) で4バケット順序 (study-exact → local-exact → study-prefix → local-prefix → connection) で候補を並べる（詳細は dictionary-system.md）

## 既知の制約

- IMEはLSBackgroundOnlyのため、`NSApp.unhide(nil)` は使えない。`orderFront(nil)` のみ（ADR-005）
- NSPanelの`.nonactivatingPanel`は必須。通常のNSWindowだとフォーカスを奪う（ADR-006）
