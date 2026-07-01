# Spec: 辞書システム

> Trigger: WordSearch.swift, ConnectionDict.swift
> Last updated: 2026-06-23 (候補削除はstudy/local両方から削除)

## 概要

3階層の辞書を優先度順に検索し、候補を返す。

## 辞書の優先度

| 優先度 | 辞書 | ファイル | 最大件数 | 特徴 |
|--------|------|---------|---------|------|
| 1 (最高) | Study | ~/.gyaim/studydict.txt | 10,000 (設定可能) | MRU淘汰（デフォルト） |
| 2 | Local | ~/.gyaim/localdict.txt | 無制限 | ユーザー手動登録 |
| 3 | Connection | Resources/dict.txt または ~/.gyaim/connectiondict.txt | ~40K | 形態素解析辞書。インポート済み辞書があれば優先 |

## ファイル形式

Study: タブ区切り `reading\tword\ttimestamp\tfrequency`（旧2カラム形式も読み込み可能）
Local: タブ区切り `reading\tword`
Connection: タブ区切り `romaji\tsurface\tinConnection\toutConnection`

## 接続辞書の思想

接続辞書は単なる `reading -> word` 辞書ではなく、「単語カテゴリ」と「次に接続できるカテゴリ」による状態遷移辞書である。増井俊之氏の Gyaim / Gictionary 由来の中核設計で、単純な再帰探索でも複合語・活用・漢数字などを生成できる。

Gictionary上のエントリは概念的に以下の形を持つ。

```text
読み 単語カテゴリ 次カテゴリ
読み 単語カテゴリ
```

SwiftyGyaim の `dict.txt` / `connectiondict.txt` ではカテゴリ名を数値化し、以下のTSVとして扱う。

```text
romaji surface inConnection outConnection
```

- `inConnection`: このエントリが受け入れるカテゴリ
- `outConnection`: このエントリの後ろに接続できるカテゴリ。次カテゴリなしは `0`
- `ConnectionDict.generateCand()` は、入力の先頭に合う語を見つけると残りの入力を `outConnection` で絞って再帰探索する
- 表記に含まれる `*` は内部接続用マーカー。`ConnectionDict` はこれを `canStart` / `canTerminate` / `contributesSurface` に正規化して扱う

例: `けいおう 大学名 大学名接続` と `だいがく 大学名接続 名詞接続` があれば、`けいおうだいがく` から `慶應大学` を生成できる。動詞活用も同様に `むす -> 結`、`べ -> *べ*`、`ない -> *ない` のような接続で `結べない` を生成する。

生産的な接尾辞も接続辞書で扱う。`化` は suffix-only の `*化` として `名詞接続/普通名詞接続 -> する接続` に追加し、`局所 + 化 -> 局所化`、`局所 + 化 + する -> 局所化する` のような候補を通常辞書検索で生成する。先頭 `*` により単独 `ka` のトップレベル候補は増やさず、接続経路上でのみ利用する。

同じ方針で `*的` と `*性` も suffix-only として扱う。`*的` は `名詞接続/普通名詞接続 -> 形容動詞接続` に接続し、`抽象的` / `抽象的な` / `抽象的に` などを生成する。`*性` は `形容動詞接続/普通名詞接続 -> 普通名詞接続` に接続し、`再現性` / `安全性` / `技術性` などを生成する。任意の短い普通名詞から `用性` のようなノイズを作らないため、一般名詞 `3 -> 4` からは直接接続しない。

活用語尾も同じ接続辞書モデルで補う。`*ったら` は `終わ -> *ったら` のように r行系語幹から接続し、`終わったら` / `変わったら` / `書いたら` などの条件形候補を生成する。

### 接続ノードの表示ポリシー

`ConnectionDict` は読み込んだ `word` を以下の表示ポリシーに分解する。

| フィールド | 意味 |
|------------|------|
| `canStart` | トップレベル候補として開始できるか |
| `canTerminate` | このエントリで候補を終端してよいか |
| `contributesSurface` | このエントリの surface を表示文字列へ足すか |

`*` 付き語尾は `*` を除いた surface を保持しつつ、先頭 `*` で `canStart=false`、末尾 `*` で `canTerminate=false` とする。たとえば `*べ*` は単独開始・終端できないが、後続があれば `べ` を surface に寄与する。`*ない` や `*化` は単独開始できないが終端でき、surface には `ない` / `化` を寄与する。

一方、`い形容詞` / `な形容詞` などの接続カテゴリ風ノードは `canStart=false`, `canTerminate=false`, `contributesSurface=false` として扱う。これにより探索用ノードとして connectionLink には残しつつ、`omoku = omo + ku = 重 + い形容詞` のような内部ラベル混入候補を生成しない。

## 接続辞書インポート

設定画面の「接続辞書」セクションからURLを指定し、Gictionaryリポジトリの `dict2.txt` 形式（接続辞書TSV）を `~/.gyaim/connectiondict.txt` にインポートできる。`Gictionary.json` も読み込み可能だが、リポジトリ同梱の現行辞書と完全一致させたい場合は `dict2.txt` を指定する。

### 使い方

推奨URLは以下のいずれか。

```text
https://github.com/masui/Gictionary
https://raw.githubusercontent.com/masui/Gictionary/master/dict2.txt
```

`https://github.com/masui/Gictionary` のようなGitHubリポジトリURLを指定した場合は、自動的に `https://raw.githubusercontent.com/masui/Gictionary/master/dict2.txt` として扱う。`/blob/<branch>/dict2.txt` URLもraw URLへ正規化する。未入力でインポートした場合も推奨raw URLを使用する。

- 設定キー: `connectionDictSourceURL`（最後に成功したインポート元URL。`~/.gyaim/settings.json` に保存し、既存UserDefaults値は後方互換fallbackとして読む）
- 保存先: `Config.importedConnectionDictFile` = `~/.gyaim/connectiondict.txt`
- 起動時/再読み込み時は `Config.activeConnectionDictFile(bundleDictPath:)` で、インポート済みファイルが存在し非空ならそれを使用し、なければbundle内 `Resources/dict.txt` を使用する
- インポート成功後は `GyaimController.reloadConnectionDictionary()` で現在の `WordSearch` を作り直し、再起動せずに反映する
- 「内蔵辞書に戻す」で `~/.gyaim/connectiondict.txt` とURL設定を削除し、bundle辞書を再ロードする

### Gictionary JSON の解釈

元リポジトリ: https://github.com/masui/Gictionary

`Gictionary.json` の各pageを1語として扱い、`page.title` を表記、`page.lines` の先頭から以下の形の行を接続辞書エントリとして読む。

```
読み 単語カテゴリ 次カテゴリ
読み 単語カテゴリ
```

- JSON exportでは `lines[0]` にtitle行が含まれるため、`line == page.title` はスキップする
- 空行、`[[...]]` を含む行、2〜3フィールド以外の行に到達したら、そのpageのエントリ読み取りを終了する（Gictionaryの `programs/getdict` と同様に、説明文以降を辞書エントリとして扱わない）
- `#` コメント行はスキップし、行末の空白+`#`以降はコメントとして削除する
- 読みがひらがなで始まる場合は `RomaKana.hiragana2roma()` でローマ字候補に展開する。ひらがな以外で始まる場合は元の読みをそのままpatternにする
- 単語カテゴリ/次カテゴリには出現順で1始まりのconnection番号を割り当て、次カテゴリなしは `outConnection = 0` とする

## 候補安全フィルタ

`WordSearch.search()` は study/local/connection 由来候補を返す直前に表示安全性を検証する。空白のみ、80文字超、改行またはNULを含む候補は除外する。これは誤学習や外部テキスト混入で、複数行のメモ・設定・secret説明文などがIME候補やログに出ることを防ぐため。

connection 候補については、`ConnectionDict` が内部接続ラベル風ノードを `contributesSurface=false` として扱い、`重い形容詞` / `おもい形容詞` のような候補を生成段階で出さない。さらに `WordSearch` の connection 候補追加直前でも、候補全体が `い形容詞` などの内部ラベル suffix で終わる場合だけ狭く除外する。これはインポート済み辞書などで未知の内部ラベルが残る場合の防御層で、study/local 候補には適用しない。

## 検索モード

| mode | 名称 | トリガー | 動作 |
|------|------|---------|------|
| 0 | 前方一致 | 文字入力ごと | inputPatの前方一致で候補を返す（インクリメンタル） |
| 1 | 完全一致 | Space（候補なし時） | inputPatの完全一致 + ひらがな/カタカナ自動追加 |
| 2 | Google | トリガー文字/ショートカット | GoogleTransliterate APIの結果 |

## 学習の仕組み

### StudyEntry

学習辞書の各エントリは以下のメタデータを保持する:

| フィールド | 型 | 説明 |
|-----------|------|------|
| reading | String | 読み（ローマ字） |
| word | String | 変換後の語 |
| lastAccessTime | TimeInterval | 最終使用時刻（epoch秒） |
| frequency | Int | 使用回数 |

### study()
- **平仮名スキップ**: `studyHiraganaEnabled` がOFFの場合、wordが全てひらがな（U+3040-U+309F）ならスキップ。デフォルトON（後方互換）。UserDefaultsキー `studyHiraganaEnabled`（Bool）
- 既存エントリ: `lastAccessTime` を更新、`frequency` をインクリメント、先頭に移動
- 新規エントリ: `StudyEntry(lastAccessTime: now, frequency: 1)` を先頭に挿入
- 上限超過時に淘汰方式に応じたevictionを実行
- 同じ単語がstudyDictに既存かつconnectionDictに未登録の場合、localDictに昇格（`register()`）
- **ファイル保存**: evict後に `saveStudyDict` を呼び即座に永続化する。これをしないと、IMEプロセスが `deactivateServer` を経由せず終了したとき（killall, クラッシュ等）に学習データがすべて失われる。保存は原子的（tempfile + rename）なのでクラッシュ耐性がある。

### 淘汰方式（EvictionMode）

設定画面から3つの方式を選択可能。UserDefaultsキー `studyDictEvictionMode`（Int）。

| モード | rawValue | 説明 | 淘汰ロジック |
|--------|----------|------|------------|
| MRU | 0 (デフォルト) | Gyaim従来方式 | 上限超過時に末尾切り捨て |
| 淘汰なし | 1 | 末尾切り捨てのみ | MRUと同じ（上限10,000件） |
| スコアベース | 2 | Mozc風 | 先頭100件を保護し、残りからスコア最低のエントリを削除 |

### スコア計算（スコアベースモード）

```
score = lastAccessTime + log2(max(frequency, 1)) * 3600 - word.count * 600
```

- `lastAccessTime`: 最終使用時刻が新しいほど高スコア（支配的要因）
- `log2(frequency) * 3600`: 頻度2倍 ≈ +1時間の鮮度ボーナス
- `word.count * 600`: 文字1つ ≈ -10分のペナルティ（短い語を優遇）

### register()
- `localDict` に `[reading, word]` を追加
- ファイルに即座に書き出し

### deactivation時はstudy()をスキップ
IME切替による自動確定ではユーザーが意図的に候補を選んでいないため、`fix(skipStudy: true)` で学習を抑制する。

## ホットリロード

`search()` 呼び出し時に `localdict.txt` のmtimeをチェックし、変更があれば再読み込み。DictEditorWindowでの編集を即座に反映するため。

## 検索上限

`search()` の `limit` パラメータはデフォルト0（無制限）。mozcと同様に候補数に上限を設けない方針。`limit > 0` を指定すると、study/local辞書の早期break + connection辞書のearly returnで制限される。

## 候補削除（ADR-015）

候補表示中にShift+X（または設定済みショートカット）で、選択中の候補を辞書から削除する。

### deleteFromStudy(word:reading:) -> Bool
- 学習辞書から指定エントリを削除し、即座にファイル保存
- エントリが見つからない場合はfalseを返す

### deleteFromLocal(word:reading:) -> Bool
- ユーザー辞書から指定エントリを削除し、即座にファイル保存
- mtimeを更新してホットリロードと整合

### deleteFromUserDictionaries(word:reading:) -> Bool
- 候補削除UIから使う統合削除
- 同じ word/reading が study と local の両方に存在する場合、両方から削除する
- 片方だけ削除してもう片方から復活するのを防ぐ

### CandidateSource / CandidateKind
SearchCandidate は `source` で候補の出自、`kind` で候補の性質を追跡する。

`source`:
- `.study` / `.local` → 削除可能。削除操作では同じ word/reading を study/local 両方から削除する
- `.connection` / `.google` / `.external` / `.synthetic` → 削除不可

`kind`:
- `.exact` / `.prefix` → 辞書候補の読み一致種別
- `.raw` → ローマ字そのまま
- `.compound` → connection dict の複数エントリ合成候補、または AI Tab 用 CandidateGenerator 生成候補
- `.lattice` / `.completion` → AI Tab 用 CandidateGenerator 生成候補
- `.zenz` → 同梱Zenzの制約付き生成候補
- `.google` → Google Input Tools 候補
- `.kana` → ひらがな/カタカナ候補

### AI Tab候補の位置づけ

AI候補生成は通常入力では自動実行せず、明示的なTab起動時にだけ使う補完レイヤーである。主経路は study/local/connection 辞書候補であり、AIは接続辞書やユーザー辞書だけでは候補が弱い場合に補助する。したがってAI候補生成・rerankは、接続辞書の状態遷移モデルを必ず厳密に再現する必要はない。ただし、通常辞書候補の順位・出自・削除可否を壊さないこと。

## 通常入力の軽量コンテキストrerank

prefix mode では `aiRerankFastContextEnabled=true`（デフォルトON）のとき、`WordSearch.search()` が返した辞書候補に対して、`GyaimController.buildPrefixCandidates()` が上位24件だけ同期的に `AIReranker.localRerank` へ渡す。これは候補生成を伴わない軽量rerankで、Tab起動のAI候補生成とは別物。

目的:
- `したがう` に対する `従う` と `従うな` のように、読み完全一致候補と長い予測候補の順序を自然にする
- 直前文脈が強く予測候補を支持する場合だけ、予測候補を上げられる入口を作る
- 速度を保つため、外部サーバー・Zenz生成・Googleは呼ばない

制約:
- raw input は常に先頭維持
- クリップボード/選択テキスト候補は辞書候補より前に維持
- rerank対象は辞書候補上位24件のみ（`aiRerankFastContextCandidateLimit` で 2〜48 に調整可能）
- 低確信時は exact reading を prefix prediction より優先する
- 既定では Swift heuristic のみを使う。`aiRerankUseModelForFastContext=true` の場合だけ in-process model backend を使う
- 入力ごとの latency ログは `aiRerankFastContextLoggingEnabled=true` のときだけ出す

## 完全一致reading優先（ADR-016 → ADR-017）

設定画面のトグルで有効/無効を切り替え可能。UserDefaultsキー `exactReadingMatchPriority`（Bool、デフォルトfalse）。

有効時、前方一致検索（searchMode == 0）で**辞書をまたいだ4バケット順序**で走査（ADR-017）:

```
1. studyDict exact   (entry.reading == query)
2. localDict exact   (yomi == query)
3. studyDict prefix  (regex prefix match)
4. localDict prefix
5. connectionDict    (single pass, 現状の挙動)
```

各バケット内のMRU順序は維持。connection dictは単一バケット維持（静的辞書の単漢字exactで予測候補が押し流されるのを避けるため）。

dedup は `word` 単位の先着勝ちなので、user-owned dict (study/local) が先に列挙されることで `source = .connection` で上書きされず、Shift+X による候補削除（`GyaimController.deleteCurrentCandidate`）が機能する。

OFF時は単一パス（study → local → connection）で従来どおり MRU 順。

## studyDict のプロセス内共有（BUG-005）

`studyDict` と `studyDictFile` は `WordSearch` の **static 変数**（プロセス全体で共有）。InputMethodKitはクライアントアプリごとに別の `GyaimController`/`WordSearch` インスタンスを生成するため、インスタンス変数にすると各インスタンスが独立したメモリを持ち、ある インスタンスの `saveStudyDict` が他インスタンスの学習データを上書きして消す。

- init() は `studyDictFile` パスが変わった場合のみファイルから再読み込み
- `resetStudyDict()` はテスト専用（テスト間のアイソレーション）
- `localDict` はインスタンス変数のまま（mtime ホットリロードがあり、マルチインスタンスでの上書き問題は `register()` 頻度が低いため実害なし）

## 既知の制約

- studyDictは起動時に全件メモリ読み込み（10,000件で<1MB）
