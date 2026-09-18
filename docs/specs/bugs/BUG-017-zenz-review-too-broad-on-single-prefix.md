# BUG-017: fast-context Zenz review が1文字 prefix で広すぎる置換を行う

- **発見日**: 2026-06-19
- **症状**: dogfood log の `review-fixed` で、`kouh -> 高品質`、`tukat -> つかっちゃ`、`kaiz -> 会場` のように、Swift heuristic の最上位候補から文脈に合わない候補へ先頭が大きく入れ替わるケースが目立つ。
- **影響**: model backend を ON にした dogfood で、fast-context の安全な exact / prefix heuristic を Zenz review が上書きし、通常入力中の第一候補品質が不安定になる。
- **原因**: `evaluateCandidate` の `fixRequiredPrefix` は、最初に不一致になった model 最尤 token までの prefix を返す。ログ上の `review fixed` 160件中157件が1文字 prefix で、`高` / `つ` / `ど` のような短すぎる prefix が既存候補の `hasPrefix` 判定に一致し、広すぎる候補移動を許していた。
- **修正**: fast-context review の既存候補置換では、trim 後2文字未満の `fixRequiredPrefix` を採用しない。また prefix が現在の最上位候補自身に一致する場合は順位変更として扱わず、local order を維持する。
- **検証**: `ZenzRuntimeTests` に、1文字 prefix が置換されないこと、2文字以上の prefix は既存候補へ移動できること、現在の最上位候補自身は replacement にならないことを確認するテストを追加。
- **教訓**: token 単位の model review 結果を候補順位へ変換するとき、1 token / 1文字 prefix は制約として弱すぎる。特に IME の通常入力中 rerank では、候補集合内 `hasPrefix` に直接流す前に prefix 長・現在候補との同一性・安全性を検証する。
