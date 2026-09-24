# ADR-028: モデル寄与を確定順位差で測り、先頭保護と下位推薦を分離する

## Status

Accepted (2026-09-13). 採点件数（Decision 3）は ADR-031 で置き換え

## Decision

1. 通常入力のrequestをcontroller UUID / composition ID / generationで識別する。既存opt-in確定ログにheuristic順位・提案順位・適用順位・採点集合/スコア・モデル/outcomeを紐付け、同じ確定語に対する順位の改善/悪化を測る。同期・遅延をともに対象とし、skip・採点失敗・確定前キャンセルを区別する。
2. 同音異義語の先頭選定後、採点済みの下位候補のスロット同士をモデルスコア順に入れ替える。先頭・未採点/除外候補の位置はこの追加操作では固定。同点は元順を維持し、有効な先頭スコアがなければ何もしない。
3. 採点集合は既存の上位3件（設定上限も変更なし）。モデル呼び出し数・頻度係数・先頭選定アルゴリズムは変更しない。

## Context

[調査](../internal/model-contribution-investigation-2026-09-12.md)で、現在のモデル経路は先頭へ昇格できない提案を下位にも活かしていないことが分かった。一方、無条件の頻度ガード緩和やPMI置換を支持する十分なデータはない。先頭変更率と解釈していたtopChangedも、実装は上位8件の配列比較だった。

## Consideration

- 先頭ガードを弱める: BUG-036の反復表記の誤上書きが再発し得る。少数回の学習を信頼度で扱う案は、評価ログと時系列holdoutを整えてから判断する。
- 全候補をモデル順にする: 未採点との比較が不公平になり、遅延も増える。採点済みスロットだけの並べ替えを採用する。
- 最大スコアの挑戦者が失格なら次点の先頭昇格を試す: 先頭の挙動が変わるため別変更として評価する。

## Consequences

- モデルの先頭判定を維持したまま、2位以下の選択順位を改善できる可能性がある。一方で下位順位の悪化もあり得るため、`modelEffect.byOutcome` の `exact-homophone-tail-reranked` を観測する。
- rank差は観測された確定選択に対する代替指標で、位置バイアスを除いた因果的accuracyではない。
- ログはローカル・既存設定によるopt-in。追加候補metadataはprivate語彙を含むので、無断共有/学習はしない。ログ出力のheadを制限し、raw/外部候補の表層を新たに列挙しない。
- 推論は引き続きメインスレッドであり、ADR-026をsupersedeしない。採点開始後の打鍵待ちは残る。バックグラウンド化は設定/affinityのsnapshotと適用前stale guardを整え、別ADRで扱う。

## References

- [AI rerank仕様](../specs/ai-rerank.md)
- [入力フロー](../specs/input-flow.md)
- [ADR-021](021-exact-homophone-direct-logprob.md)
- [ADR-026](026-deferred-model-review.md)
