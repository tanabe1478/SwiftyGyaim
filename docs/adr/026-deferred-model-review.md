# ADR-026: 通常入力のモデルレビューを打鍵から切り離して遅延実行する

## Status

Superseded by ADR-029

## Decision

fast-context rerank（ADR-016/017/020/021）のうち、同梱言語モデルによるレビュー（通常レビューと exact 同音異義語レビュー）を、打鍵と同期して実行するのをやめる。打鍵時は Swift heuristic だけで候補を並べて即座に表示し、入力が `aiRerankFastContextReviewDelayMs`（既定 80ms、0 で従来の同期実行）の間止まったときだけ、同じ入力に対してモデルレビューを走らせて候補順を差し替える。次の打鍵・確定・リセットで保留中のレビューは破棄する。

あわせて、IME activate 時にモデルをバックグラウンドで先読みする（`InProcessAIReranker.warmUp`）。

## Context

dogfood ログ（2026-09-11〜12、確定 603 件）で、同音異義語レビューは 760 回走ったが、そのまま確定に至ったのは 26 回だった。残りは打鍵途中の入力に対する実行で、1 回 20〜27ms（p95 68ms）を毎打鍵で払っていた。4 文字入力の p95 レイテンシ 56ms はこの無駄撃ちが原因で、初回のモデルロード（1.9 秒）も打鍵に乗っていた。

## Consideration

- 同期実行のまま入力長ゲートを上げる: fix が出る主戦場（4 文字の同音異義語）を切り捨てるため不可。
- バックグラウンドスレッドで実行: `ContextDict` はロック済みだが `GyaimController` の状態（`candidates`、`nthCand`）はメインスレッド前提。`DispatchQueue.main.asyncAfter` で遅延させれば、状態はメインスレッドに留まり、モデル呼び出し自体も従来と同じ経路（`BundledZenzRuntime` のロック内）で走る。採用。
- Google 変換と同じ「stale guard」方式で結果適用: `inputGeneration` カウンタと `inputPat` / `searchMode` / `nthCand` の一致を確認してからだけ候補を差し替える。ユーザーが Space で候補を送っていた場合（`nthCand > 0`）は差し替えない。

## Consequences

- 高速に打鍵している間はモデルが走らず、止まった瞬間に 1 回だけ走る。
- ログの outcome に `heuristic-prereview`（同期パス、後でモデルが走る予定）が増える。`aggregate-fast-context-log.py` の集計ではモデル経路の件数は実際にモデルが走った回数を表すようになる。
- 候補ウィンドウが遅延後に 1 回並び替わることがある（Google 変換の 2 段階更新と同じ挙動）。既定 80ms は通常の打鍵間隔より短いため、連続入力中には起きない。
- 実機での体感確認は未実施（本 ADR 作成時点）。設定 `aiRerankFastContextReviewDelayMs=0` で即座に従来動作へ戻せる。

## References

- `docs/specs/input-flow.md` AI rerank
- issue #57（計測基盤）、#94（誤確定の自己強化ループ）
