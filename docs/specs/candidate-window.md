# Spec: 候補ウィンドウ

> Trigger: CandidateWindow.swift, CandidateWindowPositioner.swift, ClassicBubbleBackground.swift, PreferencesWindow.swift, PreferencesSection.swift, PreferencesSections+Input.swift, PreferencesSections+Ranking.swift, ShortcutRecorderRow.swift
> Last updated: 2026-11-06 (表示モードの切替を全ウィンドウに届かせる appliedDisplayMode — BUG-047、設定画面をセクション型 + スクロールに作り直し、即時保存・全項目リセット・単独キーの設定 UI)

## 概要

NSPanelベースの非アクティブウィンドウ。フォーカスを奪わない（`.nonactivatingPanel`）。

## 表示モード

| モード | 1ページ表示数 | レイアウト | 選択表示 |
|--------|-------------|----------|---------|
| list | 9 | 縦リスト、番号1-9（10番目以降は番号なし） | ハイライト行 |
| classic | 11 | 横並び、candwin.png背景 | 下線 |

設定キー: `candidateDisplayMode` (Int, 0=list, 1=classic, デフォルト1)。設定画面で変更する値は `~/.gyaim/settings.json` に保存し、既存UserDefaults値がある場合は後方互換のfallbackとして読む。

## ページ送り

候補が1ページの表示数を超える場合、スペースキーで`nthCand`を進めると表示がスクロールする。`showCands()`が`nthCand+1`から`maxVisible`個を表示ウィンドウに渡す。

### ページインジケータ（▼）

続きの候補がある場合（`hasMore=true`）のみ、末尾に▼を表示:
- **リスト表示**: stackViewの最下部にインジケータラベル（薄い色、中央揃え）
- **クラシック表示**: テキスト末尾に` ▼`を付加

`updateCandidates(_:selectedIndex:hasMore:hasPrev:)` で制御。`hasPrev` は現在UI表示には使用しない（将来拡張用）。

## Classic背景の描画

`ClassicBackgroundView`（`ClassicBubbleBackground.swift`）: candwin.png を上部キャップ（27 px、トンガリを含む）・中央（ストレッチ）・下部キャップ（20 px）の 3 スライスで描画。候補数に応じて高さを可変。

トンガリの向き（`BubbleTailDirection`）: 元の絵はトンガリが上を向き（ウィンドウがキャレットの下にある前提）、左端から 16 px の位置に先端がある。`CandidateWindowPositioner.place()` がウィンドウをキャレットの上にフリップしたときは `tail = .down` を返し、`CandidateWindow.setBubbleTail(.down)` で絵を上下反転して描き、本文の上下インセット（27 / 20）を入れ替える。ウィンドウの高さは変わらない。クラシックモードの x はキャレットから 16 px 左に置き、トンガリの先端がキャレットに重なるようにする。

Classic表示は `NSScrollView` + `NSTextView` で候補文字列を表示する。長い候補列が折り返される場合、`layoutManager.usedRect(for:)` で必要な高さを計算した後、`NSTextView.frame` を `documentWidth x scrollHeight` に明示更新する。`documentView` のframeがゼロのままだと、白いcontent areaだけが表示され候補文字が見えないため、回帰テストで `textView.frame.width > 0` を確認する。

## 位置計算

`CandidateWindowPositioner`: クライアントから取得した`lineRect`（カーソル位置）を基準に表示位置を計算。画面境界でクランプ。`place()` は原点に加えてトンガリの向き（下に収まらずキャレットの上にフリップしたら `.down`）を返し、`calculate()` はその原点だけを返す。対象スクリーンは `lineRect` と交差する `NSScreen.visibleFrame` を優先し、見つからない場合はマウス位置のスクリーンにフォールバックする。

Mozc の `renderer/window_util.cc` も、preedit rect / target point と対象モニタの working area を入力に、候補ウィンドウを反対側へ逃がし、それでも収まらない場合は working area 内へクランプする設計になっている。本実装もこの方針に合わせ、`visibleFrame` 内に収めることを優先する。ただし SwiftyGyaim では IMK クライアントがローカル座標を返す実ログがあるため、Mozc の working area クランプに加えて `lineRect` 妥当性検証を行う。

### lineRect検証とフォールバック（Issue #10）

一部のブラウザ/Webアプリは `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` でスクリーン座標ではなく、`(13.75, 12.0, 1.0, 17.5)` やログで観測された `(34.0, 10.0, 1.0, 14.0)`, `(60.0, 10.0, 1.0, 14.0)` のようなビュー原点付近のローカル座標を返すことがある。この値をそのまま使うと候補ウィンドウが画面左下付近に出る。

`CandidateWindowPositioner.resolveLineRect()` で以下の順に表示位置用のrectを決定する:

1. 正常そうな `reportedLineRect` はそのまま使用し、`GyaimController.lastValidCandidateLineRect` に保存
2. 原点付近かつ1px幅のような疑わしいrectは、前回の正常rectを使用
3. 前回正常rectがない場合は `NSEvent.mouseLocation` から1px幅のフォールバックrectを作る

### 固定矩形の検出（ADR-038）

Chrome の Google Docs は、実キャレットの矩形と、ウィンドウ左端の固定位置にある高さ 17〜20 の矩形を入力ごとに交互に返す。`StaleCaretRectDetector.shared(for: bundle)`（bundle ごとにプロセス全体で 1 つ）に報告された矩形を記録し、同じ (x, y, 高さ) が 60 秒以内に報告済みで、直前の矩形が 300 px 以上離れていて行の高さが 2 px 以上違うとき、直前の矩形を表示位置に使う（`source=repeatedStale`）。ADR-018 の原点付近の判定に当たる矩形は検出器に通さない。`lastValidCandidateLineRect` は置き換えた矩形では更新しない。

`showWindow()` のログには `reportedLineRect`, `resolvedLineRect`, `source` を出し、フォールバック発生時の調査を容易にする。レベルは info（`loggingEnabled` 時に gyaim.log へ出す）。直前のログ行と内容が同じ場合は出さない（1 回の入力の間は矩形が変わらないため、変化点だけで十分）。Chrome の Google Docs でキャレットから離れた位置に出る報告の調査に実際の `reportedLineRect` が要るため debug から上げた（`docs/internal/dogfood-conversion-complaints-2026-10.md` ケース 3）。

## モード切替の実装

NSLayoutConstraintのactivation/deactivationで切り替え。list用のNSStackViewとclassic用のClassicBackgroundViewを両方保持し、表示時に切り替える。

候補ウィンドウはコントローラごとに 1 枚あり（`GyaimController.init` で生成）、設定画面から届くのは `CandidateWindow.shared`（最後に作られた 1 枚）だけ。そこで `applyDisplayMode()` が組み立てたモードを `appliedDisplayMode` に覚え、`updateCandidates` は設定の `CandidateDisplayMode.current` と違っていればその場で `applyDisplayMode()` を呼んでから文字を流し込む。以前は設定画面で切り替えた直後、別コントローラのウィンドウが旧モードの制約と表示 / 非表示のまま新モードで文字を流し込まれ、空の吹き出し（または空の灰色の箱）になっていた（BUG-047）。設定画面側は `CandidateDisplayMode.setCurrent` を呼ぶだけでよい。位置計算 `CandidateWindowPositioner` は `CandidateWindowPositioner.swift`。

## PreferencesWindow: 構成

`PreferencesWindow`（PreferencesWindow.swift）は `NSScrollView` の中に `PreferencesSection` の派生クラスを縦に積む。ウィンドウは内容がすべて収まる高さで開き、収まらなければ画面の `visibleFrame` の 85% を上限にしてスクロールする（以前は固定座標の手書きレイアウトで高さ 1,434 pt、MacBook 単体では下のボタンに届かなかった）。幅は `contentWidth`（540）固定。下部のバーは「初期値に戻す」と「閉じる」（Return）だけ。

- `PreferencesSection`（PreferencesSection.swift）: 見出し + 縦の `NSStackView`。`addRow` / `addLabeledRow` / `addControlsRow` / `addIndentedRow` / `addHint`（11 pt の説明。`wrappingLabelWithString` + `preferredMaxLayoutWidth` で折り返す。以前は右端で切れていた）。派生クラスはコントロールを `let` で作ってから `super.init(title:)` し、行を追加する。`reload()` で設定を読み直す
- `ClosureButton` / `ClosureSegmentedControl`: target/action を自分に向けてクロージャへ流す。テストは従来どおり `sendAction(_:to:)` / `performClick` で叩ける
- 保存はすべて即時。チェックボックス・セグメント・単独キー・ショートカット行のどれも、変更した瞬間に `GyaimSettings` / `KeyBindings.save()` へ書く。「保存」ボタンは廃止（以前はショートカットとトリガー文字だけが「保存」待ちで、Cmd+W で閉じると黙って捨てられた）
- 「初期値に戻す」は `KeyBindings.reset()` と `PreferencesWindow.resettableKeys` の全キー削除、その後 `sections.forEach { $0.reload() }`。`resettableKeys` は画面に出ている設定キーの一覧で、`GyaimSettings.knownKeys` に含まれることをテストが検査する（以前はショートカットと rerank 系 3 キーだけが戻った）
- セクション順: キー操作 → 候補 → 学習辞書 → 候補の並べ替え → 接続辞書 → ログ

### キー操作（KeyOperationSection）

- ひらがな確定 / カタカナ確定 / 候補削除: `SingleKeyField`（ShortcutRecorderRow.swift）で単独キー（ASCII 1 文字、空欄で無効 = 0）を編集。編集終了時に `validateSingleKey` を通し、不正なら beep して元に戻す。`KeyBindings.hiraganaChar` / `katakanaChar` / `deleteCandidateChar` に保存。これまで単独キー（`;` / `q` / `X`）を変える UI はなかった
- 各操作の `ShortcutListView`: 修飾キー付きショートカットの行（`ShortcutRecorderRow`、「記録」で次のキーを取る）と「+ 追加」。記録・追加・削除のたびに `onChange` で `KeyBindings` に保存。ひらがな / カタカナは最低 1 行を残す
- Google 変換: トリガー文字（`validateTrigger`: 英数字以外の ASCII 記号 1 文字。以前は不正値を黙って無視した）と、起動ショートカットの一覧

### 候補（CandidateSection）

- 表示スタイル: NSSegmentedControl（リスト表示 / クラシック表示）。設定キー `candidateDisplayMode`。候補ウィンドウ側の追従は「モード切替の実装」
- クリップボード候補 / 選択テキスト候補のチェックボックス

### 学習辞書（StudySection）

- 淘汰方式: NSSegmentedControl（MRU / 淘汰なし / スコアベース）。設定キー `studyDictEvictionMode`（ADR-014 / 025）
- 平仮名の確定を学習する（`studyHiraganaEnabled`、既定 ON）
- 完全一致の読みを優先する（`exactReadingMatchPriority`、既定 OFF、ADR-016/017。ON で study-exact → local-exact → study-prefix → local-prefix → connection の 4 バケット順）
- 「疑わしい学習エントリを確認...」（`StudySuspectsWindow.show()`）と「ユーザー辞書を編集...」（`DictEditorWindow.show()`）

### 候補の並べ替え（RankingSection）

旧「AI・文脈学習」セクション（issue #61）と学習辞書セクションの rerank 項目を 1 つにまとめ、文言を ADR-032 以降の実態に合わせた。

- 通常入力で候補を並べ替える（`aiRerankFastContextEnabled`、既定 ON）
- 並べ替えに同梱モデルを使う（`aiRerankUseModelForFastContext`、既定 OFF）。ON で辞書候補を一括採点し、学習頻度・文脈学習・複合語の加点と合わせて並べる（ADR-032）
- 同梱モデルを読み込む（`aiRerankUseBundledZenz`、既定 ON）。OFF でモデル経路を止める。旧文言「AIモデル（同梱Zenz）で候補を評価する」は gyaim-lm への置き換え後に実態と合わなくなっていた
- 並べ替えのレイテンシと順序をログに出す（`aiRerankFastContextLoggingEnabled`、既定 OFF。入力ごとに出るため）
- 文脈学習を使う（`contextLearningEnabled`、既定 ON、ADR-020）。OFF で ContextDict の記録・affinity 参照を停止（既存エントリは保持）。「学習済みの文脈: N件」と「文脈学習をクリア」（`ContextDict.shared.clear()`）
- 実験的パラメータ（margin・閾値・候補数上限・重み）は設定ファイルのみで、UI には出さない

### 接続辞書（ConnectionDictSection）

- URL 入力欄: Gictionary リポジトリ URL または `dict2.txt` raw URL。空欄なら推奨 raw URL
- 「インポート」: ダウンロードして `~/.gyaim/connectiondict.txt` に変換・保存し、`GyaimController.reloadConnectionDictionary()` で即反映
- ステータス: 内蔵辞書 / インポート辞書（サイズ）、インポート件数、エラー
- 「内蔵辞書に戻す」: インポート済みファイルと URL 設定を削除し、bundle の辞書を再ロード

フォーマットと読み込み順は `dictionary-system.md`。

### ログ（LogSection）

- ロギングを有効にする（`loggingEnabled`）、gyaim.log のサイズ、「ログを削除」「Finder で表示」

## PreferencesWindow: 標準Commandショートカット

IME本体は `LSBackgroundOnly` で通常のメインメニューを持たないため、設定画面では `Cmd+W` / `Cmd+V` などのメニュー由来ショートカットがそのままでは届かない場合がある。

`PreferencesWindow.performKeyEquivalent(with:)` で以下を明示的に扱う:

- `Cmd+W`: 設定画面を閉じる
- `Cmd+X` / `Cmd+C` / `Cmd+V` / `Cmd+A`: first responder へ標準 text action を送る
- `Cmd+Z` / `Shift+Cmd+Z`: undo / redo action を送る

ショートカット記録中は local event monitor が keyDown を先に消費するため、記録UIでは従来どおり Command 系ショートカットを登録できる。

## 既知の制約

- IMEはLSBackgroundOnlyのため、`NSApp.unhide(nil)` は使えない。`orderFront(nil)` のみ（ADR-005）
- NSPanelの`.nonactivatingPanel`は必須。通常のNSWindowだとフォーカスを奪う（ADR-006）
