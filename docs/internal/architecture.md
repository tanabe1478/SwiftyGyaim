# 全体アーキテクチャ

## 概要

SwiftyGyaim は macOS の InputMethodKit を使った日本語 IME です。アプリとしては `LSBackgroundOnly` のバックグラウンドアプリとして動作し、入力ソースに選択されたときに `IMKInputController` のサブクラス `GyaimController` がキーイベントを受け取ります。

大きく分けると、以下の責務に分かれます。

| 領域 | 主なファイル | 役割 |
|---|---|---|
| IME起動 | `main.swift`, `AppDelegate.swift` | `IMKServer` 起動、ライフサイクル、終了時保存 |
| 入力制御 | `GyaimController.swift` | キーイベント処理、変換状態管理、確定、候補表示制御 |
| 変換 | `RomaKana.swift`, `WordSearch.swift`, `ConnectionDict.swift` | ローマ字かな変換、辞書検索、学習 |
| 候補UI | `CandidateWindow.swift` | 非アクティブ候補ウィンドウ、表示モード、位置計算 |
| 設定UI | `PreferencesWindow.swift`, `KeyBindings.swift` | ショートカット、候補設定、Google変換、学習設定 |
| 辞書編集 | `DictEditorWindow.swift` | `~/.gyaim/localdict.txt` の編集 |
| 外部候補 | `CopyText.swift`, `GoogleTransliterate.swift` | クリップボード/選択テキスト/Google候補 |
| ログ | `GyaimLogger.swift` | os.Logger とファイルログ |

## プロセス構成

```text
macOS Input Source
      │
      ▼
SwiftyGyaim.app  (LSBackgroundOnly)
      │
      ├─ main.swift
      │   └─ IMKServer(name: "Gyaim_Connection", bundleIdentifier: ...)
      │
      ├─ AppDelegate
      │   ├─ Config.setup()
      │   ├─ クリップボード定期ポーリング
      │   └─ 終了時 study dict 保存 / ログflush
      │
      └─ GyaimController (IMKInputController)
          ├─ handle(_:client:) でキー入力を受ける
          ├─ WordSearch で候補検索
          ├─ CandidateWindow に候補を表示
          └─ IMKTextInput.insertText / setMarkedText でクライアントへ反映
```

## 中心となる状態

`GyaimController` が IME の入力状態を持ちます。

| 変数 | 意味 |
|---|---|
| `inputPat` | 現在入力中のローマ字パターン |
| `candidates` | 現在の候補配列 |
| `nthCand` | 選択中候補のインデックス |
| `searchMode` | `0=前方一致`, `1=完全一致`, `2=Google結果` |
| `clipboardCandidate` | 入力開始時点のクリップボード候補 |
| `selectedCandidate` | 入力開始時点の選択テキスト候補 |
| `pendingGoogleQuery` | Google変換のstale guard用クエリ |

`converting` は `!inputPat.isEmpty` の computed property です。

## 入力から候補表示までの大まかな流れ

```text
NSEvent keyDown
  │
  ▼
GyaimController.handle(_:client:)
  │
  ├─ ショートカット判定
  │   ├─ ひらがな確定
  │   ├─ カタカナ確定
  │   ├─ Google変換
  │   └─ 候補削除
  │
  ├─ 通常キー処理
  │   ├─ ローマ字を inputPat に追加
  │   ├─ Backspace / Escape / Space / Enter / 数字キー処理
  │   └─ searchAndShowCands()
  │
  ▼
WordSearch.search(query:searchMode:)
  │
  ├─ studyDict
  ├─ localDict
  └─ connectionDict
  │
  ▼
GyaimController.showCands()
  │
  ├─ 候補ページング
  ├─ ひらがな/カタカナ fallback
  └─ CandidateWindow.updateCandidates()
```

## データ保存先

ユーザーデータは `~/.gyaim/` に保存されます。

| ファイル | 用途 |
|---|---|
| `localdict.txt` | ユーザー辞書。形式: `reading<TAB>word` |
| `studydict.txt` | 学習辞書。形式: `reading<TAB>word<TAB>timestamp<TAB>frequency` |
| `copytext` | クリップボード候補用キャッシュ |
| `gyaim.log` | ファイルログ |

固定辞書はアプリバンドル内の `Resources/dict.txt` です。

## 設計上の重要な制約

### LSBackgroundOnly

IMEアプリは通常の前面アプリではありません。`NSApp.unhide(nil)` のような通常アプリ向け操作は入力先アプリからフォーカスを奪うため禁止です。

設定画面や辞書エディタを開く場合だけ `NSApp.setActivationPolicy(.accessory)` にして、閉じると `.prohibited` に戻します。

### 候補ウィンドウは non-activating panel

`CandidateWindow` は `NSPanel` の `.nonactivatingPanel` です。通常の `NSWindow` にすると候補表示のために入力先アプリのフォーカスを奪う可能性があります。

### IMKInputController は複数インスタンスになり得る

InputMethodKit はクライアントアプリごとに `GyaimController` を生成することがあります。学習辞書のようにプロセス全体で共有すべき状態は static に置く必要があります。`WordSearch.studyDict` はこの理由で static です。

## 主要な依存関係

```text
GyaimController
  ├─ WordSearch
  │   ├─ ConnectionDict
  │   ├─ StudyEntry / EvictionMode
  │   └─ GoogleTransliterate.hasTriggerSuffix
  ├─ RomaKana
  ├─ CandidateWindow
  ├─ KeyBindings
  ├─ CopyText / ClipboardMonitor
  ├─ PreferencesWindow / DictEditorWindow
  └─ GyaimLogger
```

`GyaimController` が多数の機能を束ねる中心クラスです。機能追加時は、状態遷移・候補再検索・UI更新・学習の副作用がすべてここに集まりやすい点に注意します。
