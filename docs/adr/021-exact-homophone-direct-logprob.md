# ADR-021: exact同音異義語レビューの直接logprob比較化

## Status

Accepted

## Decision

fast-context rerank の exact 同音異義語レビューを、`fixRequiredPrefix`（候補評価によるprefix制約抽出→prefix一致候補への置換）経由から、**候補ごとの条件付き平均log probabilityの直接比較**に置き換える。

- 比較対象は `BundledZenzRuntime.exactHomophoneCandidateIndices` が返す protected exact-reading 候補のみ（既定上位3件、`aiRerankExactHomophoneMaxCandidates` で最大6）
- 未完成語幹（候補集合内に `語幹+い` または `っ終わり語幹+1文字` の完成形が存在する候補）は比較対象から除外
- `LlamaZenzContext.score(prompt:continuation:)` で各候補を scoring し、現在のbestを margin（既定0.10、`aiRerankExactHomophoneMargin`）以上上回った場合のみ先頭を入れ替える
- ログ outcome 語彙（`exact-homophone-fixed/passed/kept-local/unavailable`）は維持
- あわせて `evaluateCandidate` の `best-token-is-eos` を failure ではなく pass として扱う（dogfood 2026-07 で `review-unavailable` の 437/437 件がこの reason であり、1回あたり~25msの無駄撃ちと誤警告になっていた）

## Context

BUG-020 で導入した exact 同音異義語レビューは、Zenz の candidate evaluation が返す `fixRequiredPrefix` に依存していた。この仕組みは「モデル最尤tokenと候補tokenの最初の不一致点」という間接的な信号であり、

1. prefix 一致の偶然性に依存する（`く` prefix が `くださ` にも `ください` にも一致する）
2. BUG-022（`ください` → `くださ` への再短縮）のように、防御ガードを後付けし続ける構造になっていた
3. 同音異義語同士の「どちらが文脈に合うか」という本来の問いに直接答えていない

同音異義語レビュー発動時点で比較対象は同じ読みのexact候補2〜4件に絞れているため、全候補scoringのレイテンシ問題は発生しない。

## Consideration

1. **fixRequiredPrefix 方式の維持 + ガード追加**: BUG-022 型の隙間が構造的に残る。却下。
2. **直接logprob比較（採用）**: 候補数が有界（≤6）で、`score()` は既にTab経路で実装済み。margin により モデルノイズでの先頭フラッピングを防ぐ。
3. **ContextDict（ADR-020）のみで解決**: ユーザー履歴がない初見文脈では効かない。学習ベース（ContextDict）とモデルベース（本ADR）は補完関係として両方採用。

## Consequences

- 良い点: 置換先が scoring 対象（=protected exact かつ 完成形）に限定されるため、prefix予測候補や未完成語幹への置換がコード構造上不可能になる。
- 良い点: `best-token-is-eos` の pass 化により review-unavailable が実質消滅し、本当の失敗（tokenization等）が可視化される。
- 悪い点: 候補数×score() のためレビュー1回あたりのdecode回数は増える（有界: 既定3候補）。latency gate（p50 < 25ms / p95 < 60ms）は dogfood ログで監視する。
- 悪い点: 「同じprefixで安全な完成形へ移動する」旧挙動はなくなる（完成形がprotected exactでない場合は比較対象外）。ただしその形は heuristic 側の `incompleteStemPenalty` が引き続き抑制する。

## References

- docs/specs/bug-memory.md BUG-020 / BUG-022
- docs/specs/ai-rerank.md
- docs/adr/020-context-conditioned-study.md
