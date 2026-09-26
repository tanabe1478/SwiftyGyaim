# ADR-032: 候補の並べ替えを LLM 主体にし、heuristic は安全策だけにする

## Status

Accepted (2026-09-26). Supersedes ADR-021（同音異義語の直接logprob比較）と ADR-028 の下位並べ替え・ADR-031 の採点件数。

## Decision

モデル経路（入力3文字以上、`aiRerankUseModelForFastContext=true`）では、辞書候補（`aiRerankFastContextCandidateLimit`、既定24件）すべてを同梱モデルで一括採点（`scoreBatch`）し、次の合計で並べる。

```text
total = 平均logprob(候補 | 文脈, 読み)
      + aiRerankLLMStudyWeight(2.0) × log2(1 + 学習頻度)      // study 候補のみ
      + aiRerankLLMContextWeight(2.0) × ContextDict affinity
      + heuristic の安全策の減点（incompleteStem / politeNegativePrediction / punctuatedInputMismatch / rawAscii）
      − 3.0（候補が入力のひらがなそのものの場合）
```

同点と未採点の候補は heuristic 順。heuristic はモデル経路の外（3文字未満、モデル無効、採点失敗）と、打鍵直後の即時表示（prereview）に残る。同音異義語レビュー・通常レビュー（頻度ガード、先頭保護、採点6件、fixRequiredPrefix 置換）はこの経路から外す。コードは dogfood で問題がないと分かるまで残し、その後削除する。

## Context

ユーザーの方針（heuristic は元の Gyaim になく SwiftyGyaim で継ぎ足した補正の集まりで、AI 側で解決するべき）。タイピングシミュレータで、LLM + 学習頻度 + 文脈学習が今の方式とほぼ同精度だった。障害だった全件採点の遅延は scoreBatch で解消した（Release 24候補 約11ms）。

| 条件（普段 / 自然な区切り） | 変更前 | LLM 主体 |
|---|---|---|
| メイン64文・学習なし | 0.878 / 0.789 | 0.893 / 0.800 |
| held-out20文・学習なし | 0.827 / 0.822 | 0.880 / 0.849 |
| held-out・学習あり | 0.893 / 0.863 | 0.893 / 0.863 |

操作回数はすべての条件で同じか少ない。悪化は1件（文頭の kouenn で 講演 が 公園 の上）。

## Consideration

- 学習頻度の重み: BUG-036（君31 / キミ7、LLM差 約3.4）で頻出語を守るには 1.7 以上が要る。シミュレータでは 1.0 と 2.0 で同じ結果だったため、実例を守れる 2.0 にした。
- 入力のひらがなそのもの: 初回に LLM が すこし / わからない を 少し / 分からない より上にした（メインで6件）。かなキーで常に確定でき、ユーザーはそうしている（kana-intended 585件）ため、先頭に出さない。
- 設定での切り替え: 採らない。問題があればこの変更を戻す。

## Consequences

- 同音異義語以外（予測候補の先頭など）もモデルが並べる。打っている途中の並びはシミュレータで未評価で、dogfood の `commitDiagnostics` / `modelEffect` と体感で確かめる。
- 打鍵ごとの採点件数が最大6件から最大24件に増える（バックグラウンド）。
- `aiRerankExactHomophone*` / `aiRerankFastContextNormalReviewMinInputLength` はこの経路では使われない。

## References

- ADR-021、ADR-028、ADR-029（非同期レビュー）、ADR-031
- [AI rerank spec](../specs/ai-rerank.md)
