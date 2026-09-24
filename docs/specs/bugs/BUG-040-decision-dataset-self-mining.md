# BUG-040: 候補辞書へのgold self-miningでNONEの分布が変わる

- **発見日**: 2026-09-19
- **影響**: 新規Decision Modelの初期dataset builder。比較実験の採用データには含めていない。
- **原因**: trainのgold表記をtrain-only辞書へ追加すると、trainでは正解がほぼ必ず存在する。
  未知readingのvalidationではその表記が候補辞書になく、同じ生成コードでもNONE分布が変わる。
  最初の実測はtrain NONE 11.2%、validation 70.9%。gold注入フラグのような明示的な漏洩が
  なくても「候補に存在すること」自体が教師情報の漏洩になる。
- **修正**: 現builderは同梱辞書由来の競合候補を全splitに同じ規則で生成する。
  自身のgoldを候補辞書に追加しない。候補が競合しない例を選別した件数をreportし、Recallの
  母集団制限を明記する。修正後はtrain 21.2%、validation 19.9%。
- **検証**: dataset buildの再現性、holdout reading除外、context groupのsplit不変性、NONEのgold
  除去を自動test。train/validationの分布reportを実データで生成。
- **教訓**: ラベル由来候補の生成を含むpipelineではsplitを先に切るだけで十分とは限らない。
  candidate-count/source/gold-rank/NONEのsplit間分布を必ず比較する。
- **関連仕様**: [decision-model.md](../decision-model.md)
