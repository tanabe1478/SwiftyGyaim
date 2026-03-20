# ADR-014: スコアベース学習辞書淘汰

## Status

Accepted

## Context

学習辞書の上限が1,000件にハードコードされており（WordSearch.swift）、MRU（Most Recently Used）方式で末尾を切り捨てていた。ユーザーから上限を設定可能にする要望があり（issue #1）、他のIMEの淘汰方式を調査した。

- **Mozc**: LRU + スコア（時間×頻度×文字長）のハイブリッド。上限10,000件
- **SKK**: 淘汰なし、無制限
- **macOS標準**: 非公開

## Decision

3つの淘汰方式を設定画面から選択可能にする:

1. **MRU**: Gyaim従来方式（末尾切り捨て）
2. **淘汰なし**: 末尾切り捨てのみ
3. **スコアベース** (デフォルト): Mozc風スコア計算で最低スコアのエントリを淘汰

全モード共通で上限10,000件。

スコア計算: `lastAccessTime + log2(frequency) * 3600 - word.count * 600`

ファイル形式を4カラムTSV（`reading\tword\ttimestamp\tfrequency`）に拡張。旧2カラム形式も読み込み可能（自動マイグレーション）。

## Consequences

- StudyEntry構造体を導入（reading, word, lastAccessTime, frequency）
- EvictionMode enumをUserDefaultsで管理
- PreferencesWindowに淘汰方式のNSSegmentedControlを追加
- 既存のstudydict.txtは初回finish()時に新形式に自動変換される
