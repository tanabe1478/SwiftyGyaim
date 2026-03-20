# Spec: 辞書システム

> Trigger: WordSearch.swift, ConnectionDict.swift
> Last updated: 2026-03-20

## 概要

3階層の辞書を優先度順に検索し、候補を返す。

## 辞書の優先度

| 優先度 | 辞書 | ファイル | 最大件数 | 特徴 |
|--------|------|---------|---------|------|
| 1 (最高) | Study | ~/.gyaim/studydict.txt | 1000 (MRU) | 使用頻度で自動昇降 |
| 2 | Local | ~/.gyaim/localdict.txt | 無制限 | ユーザー手動登録 |
| 3 | Connection | Resources/dict.txt | ~40K | 形態素解析辞書 |

## ファイル形式

Study/Local: タブ区切り `reading\tword`
Connection: タブ区切り `romaji\tsurface\tinConnection\toutConnection`

## 検索モード

| mode | 名称 | トリガー | 動作 |
|------|------|---------|------|
| 0 | 前方一致 | 文字入力ごと | inputPatの前方一致で候補を返す（インクリメンタル） |
| 1 | 完全一致 | Space（候補なし時） | inputPatの完全一致 + ひらがな/カタカナ自動追加 |
| 2 | Google | トリガー文字/ショートカット | GoogleTransliterate APIの結果 |

## 学習の仕組み

### study()
- `studyDict` の先頭に `[reading, word]` を挿入（MRU）
- 1000件を超えると末尾を切り捨て
- 同じ単語がstudyDictに既存かつconnectionDictに未登録の場合、localDictに昇格（`register()`）

### register()
- `localDict` に `[reading, word]` を追加
- ファイルに即座に書き出し

### deactivation時はstudy()をスキップ
IME切替による自動確定ではユーザーが意図的に候補を選んでいないため、`fix(skipStudy: true)` で学習を抑制する。

## ホットリロード

`search()` 呼び出し時に `localdict.txt` のmtimeをチェックし、変更があれば再読み込み。DictEditorWindowでの編集を即座に反映するため。

## 検索上限

`search()` の `limit` パラメータはデフォルト0（無制限）。mozcと同様に候補数に上限を設けない方針。`limit > 0` を指定すると、study/local辞書の早期break + connection辞書のearly returnで制限される。

## 既知の制約

- studyDictは起動時に全件メモリ読み込み
