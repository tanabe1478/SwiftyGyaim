# 辞書・学習システム

## 中心ファイル

- `WordSearch.swift`
- `ConnectionDict.swift`
- `StudyEntry.swift`
- `RomaKana.swift`
- `DictEditorWindow.swift`

SwiftyGyaim の変換候補は、主に3層の辞書から作られます。

## 3層辞書

| 優先度 | 辞書 | 実装 | 保存先 | 特徴 |
|---|---|---|---|---|
| 1 | Study辞書 | `WordSearch.studyDict` | `~/.gyaim/studydict.txt` | 確定履歴による学習 |
| 2 | Local辞書 | `WordSearch.localDict` | `~/.gyaim/localdict.txt` | ユーザー登録語 |
| 3 | Connection辞書 | `ConnectionDict` | `Resources/dict.txt` | 固定辞書・連接対応 |

候補は `SearchCandidate` として表現されます。

```swift
struct SearchCandidate: Equatable {
    let word: String
    let reading: String?
    let source: CandidateSource
}
```

`source` は候補削除可否やUI判断に使われます。

## SearchCandidate.source

| source | 意味 | 削除可否 |
|---|---|---|
| `.study` | 学習辞書由来 | 可 |
| `.local` | ユーザー辞書由来 | 可 |
| `.connection` | 固定連接辞書由来 | 不可 |
| `.external` | クリップボード/選択テキスト等 | 不可 |
| `.synthetic` | 入力文字列、かなfallback、タイムスタンプ等 | 不可 |

## `WordSearch.search()`

入口は次です。

```swift
func search(query: String, searchMode: Int, limit: Int = 0) -> [SearchCandidate]
```

`searchMode`:

| 値 | 意味 |
|---|---|
| `0` | 前方一致。インクリメンタル候補 |
| `1` | 完全一致。Space等で明示的に変換 |
| `2` | Google結果表示。辞書検索自体はcontroller側で扱う |

処理順:

1. 空クエリなら空配列
2. local辞書のmtimeを確認し、更新されていれば再読込
3. 特殊入力を処理
   - Googleトリガーsuffix
   - `#`, `!`
   - `ds` タイムスタンプ
   - 大文字含み入力
4. Study / Local / Connection を検索
5. 重複候補を `word` 単位で除外

## 完全一致reading優先

設定 `exactReadingMatchPriority` がONかつ `searchMode == 0` の場合、前方一致候補の並びを4バケットに分けます。

```text
1. studyDict exact
2. localDict exact
3. studyDict prefix
4. localDict prefix
5. connectionDict
```

これは、短い読みの完全一致候補が長いprefix候補に埋もれる問題を避けるためです。

Connection辞書は最後に単一パスで検索します。固定辞書の単漢字exactを先に出すと、学習済みprefix候補を押し流すためです。

## ConnectionDict

`ConnectionDict` は `Resources/dict.txt` を読み込む固定辞書です。

形式:

```text
romaji<TAB>surface<TAB>input_connection<TAB>output_connection
```

内部では以下のリンクを作ります。

| リンク | 用途 |
|---|---|
| `keyLink` | 読みの先頭文字から候補リストへ辿る |
| `connectionLink` | `inConnection` 値から連接可能候補へ辿る |

検索は `generateCand()` の再帰で行われます。

```text
pat が entry.pat と一致
  → 候補を返す

entry.pat が pat から始まる
  → searchMode=0 ならprefix候補として返す

pat が entry.pat から始まる
  → 残りpatを outConnection で再帰検索
```

これにより、単語を連結した複合候補を生成できます。

## Study辞書

`StudyEntry` は以下を持ちます。

| フィールド | 意味 |
|---|---|
| `reading` | ローマ字読み |
| `word` | 確定語 |
| `lastAccessTime` | 最終使用時刻 |
| `frequency` | 使用回数 |

保存形式:

```text
reading<TAB>word<TAB>timestamp<TAB>frequency
```

旧2カラム形式も読み込み可能です。

## `WordSearch.study()`

通常確定時に呼ばれます。

主な処理:

1. 平仮名学習設定を確認
2. 既存entryなら頻度・時刻更新し先頭へ移動
3. 新規entryなら先頭に追加
4. 上限超過時にevict
5. 即時ファイル保存
6. 必要に応じてlocal辞書へ昇格

`studyDict` は static です。InputMethodKit がクライアントごとに `GyaimController` / `WordSearch` を作るため、インスタンス変数にすると別インスタンスの保存で学習データが消えるからです。

## EvictionMode

`StudyEntry.score()` は Mozc風の簡易スコアです。

```text
score = lastAccessTime + log2(frequency) * 3600 - word.count * 600
```

| モード | 内容 |
|---|---|
| `.mru` | 最近使った順。末尾を削る |
| `.none` | 淘汰なし。ただし実装上の上限処理は残る |
| `.scoreBased` | 先頭一定件数を保護し、スコア最低のものを削る |

## Local辞書

`~/.gyaim/localdict.txt` に保存されます。

形式:

```text
reading<TAB>word
```

`DictEditorWindow` で編集できます。`WordSearch.search()` は検索前にmtimeを見て、ファイルが更新されていればhot reloadします。

## RomaKana

`RomaKana` はローマ字とかなの双方向変換を担当します。

- `roma2hiragana(_:)`
- `roma2katakana(_:)`
- `hiragana2roma(_:)`
- `katakana2roma(_:)`

`rklist` を読み、ローマ字→かな、かな→ローマ字の辞書を構築します。ローマ字→かなは長いキーからgreedy matchします。

特殊処理:

- `n` + 子音 → `ん`
- 末尾 `n` → `ん`
- 二重子音 → `っ`
- `?`, `!` などの全角記号変換

## 辞書関連の注意点

- `study()` は必ず即時保存する。終了時保存だけに依存しない
- staticな `studyDict` を使い、複数controller間の上書きを防ぐ
- `CandidateSource` の先着勝ちは候補削除機能に影響する
- local辞書は外部編集されるため、mtime hot reload が必要
- Google変換のsuffix検出は `WordSearch.search()` で空候補を返し、実APIは `GyaimController` が起動する
