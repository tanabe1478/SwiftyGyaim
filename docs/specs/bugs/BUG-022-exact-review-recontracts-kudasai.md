# BUG-022: exact-homophone review が `ください` を `くださ` へ再短縮する

- **発見日**: 2026-07-01
- **症状**: guard導入後のdogfoodでも `kudasa` で `ください -> くださ` が再発した。ログ上は current best が `下さ`、Zenz prefix が `く`、replacement が `くださ` になっていた。
- **影響**: ユーザーが `kudasai` へ入力継続する途中で、未完成なひらがな語幹 `くださ` が先頭に出る。
- **原因**: 既存guardは current best と replacement の直接比較だけを見ていたため、`下さ -> くださ` は不完全短縮として検出できなかった。候補集合内に `ください` が存在することを見ていなかった。
- **修正**: exact-homophone replacement では、replacement だけでなく候補集合全体を見て、`replacement + い` に相当する完成候補がある場合は未完成語幹への置換を拒否する。同じ prefix で安全な `ください` が後続候補にあればそちらへ移動できる。Swift heuristic / offline evaluator でも `少な` / `くださ` のような末尾 `い` 欠落語幹へ `incompleteISuffixStemPenalty` を与える。
- **検証**: `ZenzRuntimeTests` に current best が `下さ` でも `くださ` を飛ばし `ください` へ到達する regression test を追加。`AIRerankerTests` と fast-context eval fixture に `sukuna -> 少な` / `kudasa -> くださ` 抑制を追加。
- **教訓**: safety guard は current best との2者比較だけでは足りない。候補集合内のより完成した候補を見て、未完成語幹への降格を拒否する。
- **2026-07-04追記**: ADR-021 で置換機構を直接logprob比較に変更し、未完成語幹は比較対象から除外（`exactHomophoneCandidateIndices`）する構造にしたため、この置換ガードのクラスは経路ごと解消。heuristic 側は `incompleteStemPenalty` に改名し、`っ` 終わり語幹（`使っ` vs `使った`）にも汎化した。
