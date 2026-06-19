# Spec: 候補ウィンドウ

> Trigger: CandidateWindow.swift, PreferencesWindow.swift
> Last updated: 2026-06-15 (軽量rerank設定を追加)

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

`ClassicBackgroundView`: candwin.pngを9スライス描画（上部/中央/下部をストレッチ）。候補数に応じて高さを可変。

Classic表示は `NSScrollView` + `NSTextView` で候補文字列を表示する。長い候補列が折り返される場合、`layoutManager.usedRect(for:)` で必要な高さを計算した後、`NSTextView.frame` を `documentWidth x scrollHeight` に明示更新する。`documentView` のframeがゼロのままだと、白いcontent areaだけが表示され候補文字が見えないため、回帰テストで `textView.frame.width > 0` を確認する。

## 位置計算

`CandidateWindowPositioner`: クライアントから取得した`lineRect`（カーソル位置）を基準に表示位置を計算。画面境界でクランプ。対象スクリーンは `lineRect` と交差する `NSScreen.visibleFrame` を優先し、見つからない場合はマウス位置のスクリーンにフォールバックする。

Mozc の `renderer/window_util.cc` も、preedit rect / target point と対象モニタの working area を入力に、候補ウィンドウを反対側へ逃がし、それでも収まらない場合は working area 内へクランプする設計になっている。本実装もこの方針に合わせ、`visibleFrame` 内に収めることを優先する。ただし SwiftyGyaim では IMK クライアントがローカル座標を返す実ログがあるため、Mozc の working area クランプに加えて `lineRect` 妥当性検証を行う。

### lineRect検証とフォールバック（Issue #10）

一部のブラウザ/Webアプリは `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` でスクリーン座標ではなく、`(13.75, 12.0, 1.0, 17.5)` やログで観測された `(34.0, 10.0, 1.0, 14.0)`, `(60.0, 10.0, 1.0, 14.0)` のようなビュー原点付近のローカル座標を返すことがある。この値をそのまま使うと候補ウィンドウが画面左下付近に出る。

`CandidateWindowPositioner.resolveLineRect()` で以下の順に表示位置用のrectを決定する:

1. 正常そうな `reportedLineRect` はそのまま使用し、`GyaimController.lastValidCandidateLineRect` に保存
2. 原点付近かつ1px幅のような疑わしいrectは、前回の正常rectを使用
3. 前回正常rectがない場合は `NSEvent.mouseLocation` から1px幅のフォールバックrectを作る

`showWindow()` のログには `reportedLineRect`, `resolvedLineRect`, `source` を出し、フォールバック発生時の調査を容易にする。

## モード切替の実装

NSLayoutConstraintのactivation/deactivationで切り替え。list用のNSStackViewとclassic用のClassicBackgroundViewを両方保持し、表示時に切り替える。

## PreferencesWindow: 接続辞書セクション

設定画面に「接続辞書」セクションを追加。

- URL入力欄: GictionaryリポジトリURLまたは `dict2.txt` raw URLを指定。空欄の場合は推奨raw URLを使う
- 「インポート」ボタン: URLからダウンロードし、`~/.gyaim/connectiondict.txt` に変換・保存する
- ステータス表示: 内蔵辞書/インポート辞書の利用状態、インポート件数、エラーを表示
- 「内蔵辞書に戻す」ボタン: インポート済みファイルとURL設定を削除し、bundle内 `Resources/dict.txt` を再ロードする

詳細なフォーマットと読み込み優先順位は `dictionary-system.md` を参照。

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
- **通常入力で軽量rerankを使う**: チェックボックス（デフォルトON）
- UserDefaultsキー: `aiRerankFastContextEnabled` (Bool, デフォルトtrue)
- `toggleFastContextRerank(_:)` アクションで即座にUserDefaultsに保存
- **軽量rerankでモデルbackendを使う（実験的）**: チェックボックス（デフォルトOFF）
- UserDefaultsキー: `aiRerankUseModelForFastContext` (Bool, デフォルトfalse)
- **軽量rerankのレイテンシをログに出す**: チェックボックス（デフォルトOFF）
- UserDefaultsキー: `aiRerankFastContextLoggingEnabled` (Bool, デフォルトfalse)
- ログ出力は入力ごとに発生するため既定OFF。dogfoodや性能確認時だけONにする

## 既知の制約

- IMEはLSBackgroundOnlyのため、`NSApp.unhide(nil)` は使えない。`orderFront(nil)` のみ（ADR-005）
- NSPanelの`.nonactivatingPanel`は必須。通常のNSWindowだとフォーカスを奪う（ADR-006）
