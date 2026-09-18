# BUG-020: fast-context model reviewがexact同音異義語を比較できない

- **発見日**: 2026-06-22
- **症状**: `どちらの` の後に `muki` を入力した場合、文脈上は `向き` が自然でも `無機` が上位に出ることがある。
- **影響**: `向き` / `無機`、`機能` / `昨日` のような同じ読みの候補が、左文脈を使わず学習・元順・heuristicだけで選ばれる。
- **原因**: fast-context の model opt-in 経路は `.exact` / `.compound` の最上位候補を `protected-exact-skip` として常にZenz reviewから除外していた。これはprefix予測候補へ沈めない安全策として有効だが、同じ読みのexact候補同士の比較まで禁止していた。
- **修正**: 左文脈があり、同じ読みの `.exact` / `.compound` 候補が複数ある場合だけ exact 同音異義語 review を許可する。Zenz の `fixRequiredPrefix` による置換先は同じ読みの `.exact` / `.compound` 候補に限定し、prefix予測候補への移動は引き続き禁止する。
- **検証**: `ZenzRuntimeTests` に、exact同音異義語レビューの発火条件と、置換先制限がprefix候補を拒否することを確認するテストを追加。
- **dogfood追記**: `exact-homophone-fixed` 30件を一次レビューしたところ、`ください -> くださ` の未完成候補昇格が1件見つかった。ひらがな候補を末尾 `い` 1文字だけ削った未完成候補へ短縮する置換を拒否し、regression test を追加。
- **教訓**: 「exact保護」は prefix 予測への誤沈降を防ぐための制約であり、同じ読みの候補間比較まで一律に止めると文脈rerankの価値が出ない。安全境界は候補kindだけでなく、同一reading内/外で分ける。また、同一reading内でも未完成なひらがな短縮候補を上げると入力途中感が強くなるため、表記の完成度も安全条件に含める。
- **2026-07-04追記**: fixRequiredPrefix 経由の置換は ADR-021 で protected exact 候補同士の直接logprob比較に置き換えた。またユーザー履歴による文脈条件付き学習（ContextDict、ADR-020）でモデルを呼ばずに同音異義語を解決する経路を追加した。
