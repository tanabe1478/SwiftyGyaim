# 機能別実装ガイド

このファイルは「この機能はどこを読めばよいか」を起点にした実装ガイドです。

## 1. 通常の日本語変換

読むファイル:

- `GyaimController.swift`
- `WordSearch.swift`
- `ConnectionDict.swift`
- `RomaKana.swift`
- `CandidateWindow.swift`

流れ:

```text
キー入力
  → inputPat更新
  → WordSearch.search()
  → candidates更新
  → CandidateWindow表示
  → Enter/数字キーでfix()
  → WordSearch.study()
```

`inputPat` はローマ字のまま保持し、表示用に `RomaKana.roma2hiragana()` を使います。辞書検索も基本的にはローマ字readingに対して行います。

## 2. ひらがな・カタカナ確定

読むファイル:

- `GyaimController.swift`
- `RomaKana.swift`
- `KeyBindings.swift`
- `PreferencesWindow.swift`

トリガー:

| 操作 | デフォルト |
|---|---|
| ひらがな確定 | F6, Ctrl+Shift+U, `;` |
| カタカナ確定 | F7, Ctrl+Shift+I, `q` |

`KeyBindings` がショートカットを管理し、`GyaimController.handle()` が変換中に判定します。

```text
matchesHiragana / matchesKatakana
  → fixAsKana(hiragana: ...)
  → RomaKanaで変換
  → insertText
  → study
```

## 3. Google変換

読むファイル:

- `GoogleTransliterate.swift`
- `GyaimController.swift`
- `PreferencesWindow.swift`
- `KeyBindings.swift`

トリガー:

- 入力末尾のsuffix。デフォルトは `` ` ``
- 設定画面で登録したショートカット

処理:

1. `GoogleTransliterate.hasTriggerSuffix()` で検出
2. `GyaimController.triggerGoogleTransliterate()`
3. `GoogleTransliterate.searchCands()` が `https://inputtools.google.com/request` を呼ぶ
4. APIが複数segmentを返したら `combineSegments()` で直積結合
5. ひらがな/カタカナ重複を `filterCandidates()` で除外
6. `SearchCandidate` 化し、`searchMode=2` で表示

stale guard:

```text
pendingGoogleQuery = originalQuery
callback時に pendingGoogleQuery == originalQuery を確認
```

これにより、遅れて返った古いAPI結果を表示しません。

## 4. クリップボード候補

読むファイル:

- `GyaimController.swift`
- `CopyText.swift`
- `AppDelegate.swift`
- `PreferencesWindow.swift`

`CopyText` は `~/.gyaim/copytext` に文字列を保存します。

更新経路は2つあります。

1. `AppDelegate` の60秒timer
2. `GyaimController.ClipboardMonitor` の0.5秒polling

候補として表示するかどうかは設定で制御されます。

`ClipboardMonitor` は `NSPasteboard.changeCount` を監視し、コピーが発生した時刻を記録します。候補表示時には「新しいコピーか」「すでに消費済みでないか」を見ます。

## 5. 選択テキスト候補

読むファイル:

- `GyaimController.swift`
- `PreferencesWindow.swift`

入力開始時に `IMKTextInput.selectedRange()` と `attributedSubstring(from:)` で選択テキストを取得し、候補に追加します。

注意点:

- アプリによって `selectedRange()` が不正値を返す
- 取得できない場合も正常系として扱う
- 候補sourceは `.external`

## 6. 候補削除

読むファイル:

- `GyaimController.swift`
- `WordSearch.swift`
- `KeyBindings.swift`
- `PreferencesWindow.swift`

トリガー:

- modifier shortcut
- 単キー `X`（Shift+X）

処理:

```text
deleteCurrentCandidate()
  ├─ candidate.source確認
  ├─ .study → WordSearch.deleteFromStudy()
  ├─ .local → WordSearch.deleteFromLocal()
  └─ 再検索して候補表示更新
```

`CandidateSource` が正しく維持されていないと、削除可能候補が削除不可になったり、固定辞書候補を削除しようとしたりします。

## 7. 学習辞書

読むファイル:

- `WordSearch.swift`
- `StudyEntry.swift`
- `PreferencesWindow.swift`

通常確定時に `study(reading:word:)` が呼ばれます。

学習しないケース:

- IME切替時の自動確定 (`skipStudy: true`)
- 平仮名学習OFFで、確定語が全ひらがな

保存は即時です。`finish()` や終了時保存だけには依存しません。

## 8. ユーザー辞書編集

読むファイル:

- `DictEditorWindow.swift`
- `WordSearch.swift`

`DictEditorWindow` で `~/.gyaim/localdict.txt` を編集します。

`WordSearch.search()` は検索前にmtimeをチェックするため、ファイル保存後は次回検索で自動反映されます。

## 9. ログ

読むファイル:

- `GyaimLogger.swift`
- `PreferencesWindow.swift`

カテゴリ:

| カテゴリ | 内容 |
|---|---|
| `input` | キー入力・確定・状態遷移 |
| `dict` | 辞書・Google変換・学習 |
| `conversion` | ローマ字かな変換 |
| `ui` | 候補ウィンドウ・設定画面 |
| `config` | 設定・ファイルI/O |

ファイルログ:

```text
~/.gyaim/gyaim.log
```

デフォルトでは無効で、設定画面から有効化します。

## 10. 設定画面

読むファイル:

- `PreferencesWindow.swift`
- `KeyBindings.swift`
- `GoogleTransliterate.swift`
- `WordSearch.swift`
- `StudyEntry.swift`
- `GyaimLogger.swift`

設定値は多くが `UserDefaults` に保存されます。

代表キー:

| キー | 内容 |
|---|---|
| `GyaimKeyBindings` | ショートカット設定JSON |
| `candidateDisplayMode` | 候補表示モード |
| `googleTransliterateTrigger` | Google変換suffix |
| `studyDictEvictionMode` | 学習辞書淘汰方式 |
| `studyHiraganaEnabled` | 平仮名学習ON/OFF |
| `exactReadingMatchPriority` | 完全一致reading優先 |
| `loggingEnabled` | ログON/OFF |

## 11. 画像・特殊入力

読むファイル:

- `WordSearch.swift`
- `ImageManager.swift`
- `Emulation.swift`

`WordSearch.search()` には特殊入力の入口があります。

| 入力 | 意味 |
|---|---|
| `ds` | 現在日時候補 |
| 大文字含み | そのままpass through候補 |
| `#` suffix | 色/画像系の入口 |
| `!` suffix | 画像検索系の入口 |

一部は現在placeholderに近く、実際の表示やキーエミュレーションは `ImageManager` / `Emulation` 側を読む必要があります。

## 機能追加時のチェックリスト

1. `GyaimController` の状態遷移に影響するか
2. 候補sourceは正しいか
3. 学習すべき確定か、skipすべき確定か
4. 設定値を `UserDefaults` に持つならPreferencesWindowとテストを更新したか
5. 候補ウィンドウ表示位置やフォーカスに影響しないか
6. 対応する `docs/specs/` と `docs/adr/` が必要か
7. ユニットテストまたはE2Eテストを追加できるか
