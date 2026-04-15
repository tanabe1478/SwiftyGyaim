# ADR-016: 完全一致readingの候補優先表示

## Status

Superseded by ADR-017 (辞書をまたいだ4バケット順序に拡張)

## Decision

前方一致検索（searchMode == 0）時に、readingがクエリと完全一致する候補を、前方一致のみの候補より先に表示するオプションを追加する。設定画面のトグルで有効/無効を切り替え可能。デフォルトはOFF（既存動作維持）。

## Context

学習辞書はMRU（最近使用順）で管理されており、前方一致検索ではMRU順に候補が返される。このため「設定画面」(reading: setteigamen)を1回使うだけで、次に「settei」と入力した際に「設定」(reading: settei)より「設定画面」が先に表示される問題があった。

これはすべての語で発生する構造的な問題で、短い読みの語を使った後に、それを前方一致として含む長い読みの語を使うと、次回から長い語が先に表示される。

### 他IMEの調査結果

| IME | アプローチ |
|-----|-----------|
| Mozc | 変換（完全一致）と予測（前方一致）をモード分離 |
| ATOK | 辞書優先度設定、同音語グループ内MRU |
| macOS日本語IM | 単純MRU（同じ問題が起きうる） |
| SKK | 学習なし、静的辞書順 |

## Consideration

### 2パス走査方式

study dict / local dictの検索を2パスに分離:
- Pass 1: `entry.reading == query`（完全一致）→ 先に候補に追加
- Pass 2: `entry.reading.hasPrefix(query) && entry.reading != query`（前方一致のみ）→ 後に追加

各パス内のMRU順序は維持されるため、同音語の学習は壊れない。

### デフォルトOFFの理由

既存ユーザーの動作を変えないため。設定画面から明示的にONにする必要がある。

## Consequences

- 有効時: 完全一致readingの候補が前方一致のみの候補より先に表示される
- 無効時: 従来通りMRU順のまま（既存動作）
- study dict検索が最大2回走査になるが、10,000件でも実用上問題ない
- UserDefaultsキー: `exactReadingMatchPriority` (Bool, default: false)

## References

- ADR-014: スコアベース学習辞書淘汰
- [Mozc UserHistoryPredictor](https://github.com/google/mozc/blob/master/src/prediction/user_history_predictor.cc)
