# Spec: 辞書システム

> Trigger: WordSearch.swift, ConnectionDict.swift
> Last updated: 2026-04-15 (ADR-017対応)

## 概要

3階層の辞書を優先度順に検索し、候補を返す。

## 辞書の優先度

| 優先度 | 辞書 | ファイル | 最大件数 | 特徴 |
|--------|------|---------|---------|------|
| 1 (最高) | Study | ~/.gyaim/studydict.txt | 10,000 (設定可能) | MRU淘汰（デフォルト） |
| 2 | Local | ~/.gyaim/localdict.txt | 無制限 | ユーザー手動登録 |
| 3 | Connection | Resources/dict.txt | ~40K | 形態素解析辞書 |

## ファイル形式

Study: タブ区切り `reading\tword\ttimestamp\tfrequency`（旧2カラム形式も読み込み可能）
Local: タブ区切り `reading\tword`
Connection: タブ区切り `romaji\tsurface\tinConnection\toutConnection`

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

### CandidateSource
SearchCandidateに`source`フィールドを追加し、各候補の出自を追跡:
- `.study` / `.local` → 削除可能
- `.connection` / `.external` / `.synthetic` → 削除不可

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

## 既知の制約

- studyDictは起動時に全件メモリ読み込み（10,000件で<1MB）
