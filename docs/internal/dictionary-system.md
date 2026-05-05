# 辞書・学習システム

このドキュメントでは、`WordSearch.swift` / `ConnectionDict.swift` / `StudyEntry.swift` を実装寄りに読みます。SwiftyGyaim の変換は、巨大な変換エンジンというより、ローマ字readingに対する複数辞書の検索と並び替えで構成されています。

## 1. 候補のデータ構造

候補は `SearchCandidate` です。

```swift
enum CandidateSource: Equatable {
    case study
    case local
    case connection
    case external
    case synthetic
}

struct SearchCandidate: Equatable {
    let word: String
    let reading: String?
    let source: CandidateSource
}
```

`word` は表示・確定する文字列、`reading` は学習や削除に使う読み、`source` は候補の出自です。

`source` は単なるメタ情報ではありません。候補削除では `.study` と `.local` だけ削除可能です。そのため検索時のdedup順序によって `source` が変わると、UI上の削除可否も変わります。

## 2. `WordSearch` の持つ辞書

```swift
private let connectionDict: ConnectionDict
private let localDictFile: String
private var localDict: [[String]]
private var localDictTime: Date

private(set) static var studyDict: [StudyEntry] = []
private(set) static var studyDictFile: String = ""
```

local辞書はインスタンス変数、study辞書はstaticです。

### なぜ studyDict は static か

InputMethodKit はクライアントアプリごとに `GyaimController` を作ることがあります。つまり `WordSearch` も複数個作られます。

study辞書がインスタンス変数だと次の事故が起きます。

```text
Aインスタンスが「乖離」を学習して保存
Bインスタンスは古いstudyDictしか知らない
Bインスタンスが別語を学習して保存
→ Bの古い配列でファイルを上書きし「乖離」が消える
```

そのため、プロセス内では `WordSearch.studyDict` を唯一の真実にしています。

## 3. 初期化

```swift
init(connectionDictFile: String, localDictFile: String, studyDictFile: String) {
    self.localDictFile = localDictFile
    self.connectionDict = ConnectionDict(dictFile: connectionDictFile)
    self.localDict = Self.loadDict(dictFile: localDictFile)
    self.localDictTime = Self.fileModTime(localDictFile)

    if Self.studyDictFile != studyDictFile {
        Self.studyDictFile = studyDictFile
        Self.studyDict = Self.loadStudyDict(dictFile: studyDictFile)
    }
}
```

connection辞書は固定辞書なので毎回 `ConnectionDict` を作ります。study辞書はファイルパスが変わった場合だけ読み直します。テストでは一時ファイルを使うため、この「パスが変わったらreload」という条件が必要です。

## 4. `search(query:searchMode:limit:)`

入口です。

```swift
func search(query: String, searchMode: Int, limit: Int = 0) -> [SearchCandidate]
```

最初にlocal辞書のmtimeを見ます。

```swift
let currentMtime = Self.fileModTime(localDictFile)
if currentMtime > localDictTime {
    localDict = Self.loadDict(dictFile: localDictFile)
    localDictTime = currentMtime
}
```

`DictEditorWindow` や外部エディタで `localdict.txt` が更新された場合、次回検索で自動反映されます。

## 5. 特殊query

通常辞書検索の前に特殊入力を処理します。

```swift
if GoogleTransliterate.hasTriggerSuffix(q) {
    return candidates
}

if q == "ds" {
    candidates.append(SearchCandidate(word: formatter.string(from: Date())))
    return candidates
}

if q.range(of: "[A-Z]", options: .regularExpression) != nil {
    candidates.append(SearchCandidate(word: q, reading: q))
    return candidates
}
```

Google suffix はここでは空候補を返すだけです。実際のAPI呼び出しは `GyaimController.searchAndShowCands()` がsuffixを見て `triggerGoogleTransliterate()` を呼びます。

`ds` は日時候補、大文字含みはpass-through候補です。

## 6. prefix / exact の正規表現

```swift
let escaped = NSRegularExpression.escapedPattern(for: q)
let pattern = searchMode > 0 ? "^\(escaped)$" : "^\(escaped)"
let regex = try? NSRegularExpression(pattern: pattern)
```

- prefix mode: `^q`
- exact mode: `^q$`

辞書のreadingに対してこの正規表現を当てます。読みはローマ字なので、正規表現もローマ字文字列に対して動きます。

## 7. exactReadingMatchPriority の4バケット

設定がONの場合、prefix検索でも完全一致readingを優先します。

```swift
let exactPriority = searchMode == 0 && Self.isExactReadingMatchPriority
```

ON時の順序:

```text
1. studyDict exact
2. localDict exact
3. studyDict prefix
4. localDict prefix
5. connectionDict
```

実装上は `candfound: Set<String>` で `word` 単位のdedupをします。

```swift
if entry.reading == q, !candfound.contains(entry.word) {
    candidates.append(SearchCandidate(word: entry.word, reading: entry.reading, source: .study))
    candfound.insert(entry.word)
}
```

ここで先に入った候補の `source` が残ります。同じ表記がstudyとconnectionの両方にある場合、studyが先なら `.study` として残り、候補削除可能になります。

## 8. OFF時の従来順序

OFF時は辞書ごとに単純に走査します。

```text
study prefix
local prefix
connection
```

MRU的な「最近学習したものが上に来る」挙動を保つためです。

## 9. ConnectionDict の実装

`ConnectionDict` は固定辞書 `dict.txt` を読みます。

```swift
struct DictEntry {
    let pat: String
    let word: String
    let inConnection: Int
    let outConnection: Int
    var keyLink: Int?
    var connectionLink: Int?
}
```

### link構造

全件を毎回線形走査すると重いので、2種類のリンクを作ります。

```swift
private var keyLink: [Int: Int] = [:]
private var connectionLink: [Int: Int] = [:]
```

- `keyLink`: `pat` の先頭文字Unicode scalar → 最初の辞書index
- `connectionLink`: `inConnection` → 最初の辞書index

各 `DictEntry` の `keyLink` / `connectionLink` は同じキーの次entryへの linked list です。配列indexでリンクリストを作る実装です。

### 再帰検索

```swift
private func generateCand(connection: Int?, pat: String,
                          foundWord: String, foundPat: String,
                          searchMode: Int,
                          callback: (...))
```

3つのケースがあります。

```swift
if pat == entry.pat {
    callback(foundWord + entry.word, foundPat + entry.pat, entry.outConnection)
} else if entry.pat.hasPrefix(pat) {
    if searchMode == 0 { callback(...) }
} else if pat.hasPrefix(entry.pat) {
    let restPat = String(pat.dropFirst(entry.pat.count))
    generateCand(connection: entry.outConnection, pat: restPat, ...)
}
```

例えば `pat` が複合語の先頭entryに一致したら、残りの `pat` を `outConnection` から再帰検索します。これにより、単語をつなげた候補を生成します。

## 10. study()

学習は `WordSearch.study(word:reading:)` が担当します。

処理は以下です。

```text
平仮名学習設定を確認
  ↓
既存entry検索
  ├─ あれば frequency++ / lastAccessTime更新 / 先頭へ移動
  └─ なければ新規entryを先頭へ追加
  ↓
evict
  ↓
saveStudyDict
```

保存が即時なのが重要です。IMEは `deactivateServer` を経由せず終了することがあるため、終了時保存だけでは学習が失われます。

## 11. StudyEntry.score()

```swift
func score() -> Double {
    let frequencyBonus = log2(Double(max(frequency, 1))) * 3600.0
    let charPenalty = Double(word.count) * 600.0
    return lastAccessTime + frequencyBonus - charPenalty
}
```

スコアは「最近使った」「頻度が高い」「短い」語を残しやすくします。

- 頻度2倍で約1時間ぶんのボーナス
- 1文字長いと約10分ぶんのペナルティ
- ただし支配的なのは `lastAccessTime`

## 12. local辞書登録と削除

外部候補確定時などに `register(word:reading:)` が呼ばれます。

```text
localDict に [reading, word] を追加
saveDict()
localDictTime 更新
```

削除は `deleteFromLocal` / `deleteFromStudy` です。どちらも削除後に即保存します。

## 13. ファイル形式

### localdict.txt

```text
reading<TAB>word
```

### studydict.txt

```text
reading<TAB>word<TAB>timestamp<TAB>frequency
```

旧形式の2カラムstudy辞書も読み込めます。互換性を保ちながら、保存時には4カラム形式へ寄せます。

## 14. 実装を読む時の注意

- `candfound` のdedup順序は候補順位だけでなく `CandidateSource` に影響する
- `studyDict` はstaticなのでテストでは `resetStudyDict()` が必要
- local辞書はインスタンス変数なので、hot reloadで外部変更を吸収する
- `searchMode=2` は辞書検索というよりcontroller側の表示状態
- `ConnectionDict` は配列indexリンクなので、`dict` の並び自体も検索順に影響する
