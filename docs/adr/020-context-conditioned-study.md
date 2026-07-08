# ADR-020: 文脈条件付き学習（ContextDict）

## Status

Accepted

## Decision

確定時に `(左文脈の末尾, reading, 確定語)` の3つ組を `~/.gyaim/contextdict.txt` に記録し、fast-context rerank 時に同じ (reading, word) の文脈suffix一致度を `contextAffinity`（0.0〜1.0）として `AIRerankCandidate` に付与する。`AIReranker` は `contextAffinityBonus = min(affinity, 1.0) * 1.50` を加点する。

- 文脈キーは確定直前の `recentCommittedText` 末尾8文字（タブ・改行除去）
- 一致判定は suffix 共通長で、2文字未満はノイズとして無視、4文字で飽和
- 最大5,000エントリのMRU淘汰、確定ごとに原子的保存
- 候補削除UI（Shift+X）は同じ word/reading の context エントリも削除する
- あわせて study 候補には `studyFrequency` を渡し、`studyFrequencyBonus = min(0.30, log2(frequency) * 0.10)` でフラットな sourceBias を頻度連続値で補正する

## Context

`向き` / `無機`、`機能` / `昨日` のような読み完全一致の同音異義語は、学習順・元順・heuristic だけで選ばれ、左文脈が反映されなかった（BUG-020）。Zenz による exact 同音異義語レビューは導入済みだが、モデル呼び出しはレイテンシコスト（p50 ~20ms）があり、ユーザー固有の語彙選好（例: 特定文脈での専門用語）はモデルでは学習できない。

Mozc などの実用IMEは、直前の確定語を条件とする文脈バイグラム学習で同じ問題を解いている。

## Consideration

1. **studydict.txt の拡張**（4カラム→文脈カラム追加）: 既存フォーマットの後方互換処理が複雑になり、文脈なし学習と文脈あり学習のスコアが混ざる。却下。
2. **新ファイル contextdict.txt（採用）**: 独立したライフサイクル・上限・淘汰を持てる。studydict と同じ「プロセス内共有 + 即時保存」パターン（BUG-005対策）を踏襲。
3. **文脈キーの粒度**: 直前1語のみ / 固定長suffix / 全文脈。直前1語は分かち書き境界が必要になるため、固定長suffix（8文字）+ 共通suffix長スケーリングを採用。「どちらの」「この素材は」のような選好を担う機能語列を安価に捉えられる。

## Consequences

- 良い点: モデル・辞書に依存せず、レイテンシほぼゼロ（O(1) lookup）で個人適応する同音異義語選択が効く。exact同音異義語レビュー（Zenz呼び出し）の発動頻度自体を下げられる。
- 良い点: `contextAffinity` は `AIRerankRequest` JSON の optional フィールドなので、外部reranker・offline evaluator にもそのまま伝搬する。
- 悪い点: ユーザー辞書ファイルが1つ増える。誤確定も文脈付きで学習されるため、候補削除UIとの連動（context エントリ同時削除）を必須とした。
- 悪い点: suffix 一致は表層一致であり、同義の文脈（「どちらの」vs「どっちの」）は汎化しない。汎化はZenzレビュー（ADR-021）が担う。

## References

- docs/specs/bug-memory.md BUG-020
- docs/specs/dictionary-system.md
- docs/adr/017-cross-dict-exact-priority.md
