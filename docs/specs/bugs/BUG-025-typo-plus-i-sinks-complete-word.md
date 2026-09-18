# BUG-025: typo由来の「+い」学習エントリが完成語をincompleteStemPenaltyで沈める

- **発見日**: 2026-07-06
- **症状**: `sitehosii` 入力で、頻度22の学習済み「してほしい」が3位に沈み、typo由来の「してほしいい」（頻度1）が1位に出た。
- **影響**: 「い」で終わる完成語すべてが、過去に「+い」のtypoを一度でも確定していると恒常的に降格される。直近24時間のaccepted rankでrank 4+确定の一因。
- **原因**: `incompleteStemPenalty`（BUG-022対策）は「候補集合に `stem+い` が存在すれば stem は未完成」と判定していた。completion側が正当な語であることを暗黙に仮定しており、studydictのゴミエントリ「してほしいい」が「してほしい」を未完成語幹に見せた。
- **修正**: `isIncompleteStemCompletion` に「stemが既に『い』で終わる場合は+い完成とみなさない」ガードを追加（Swift / Python evaluator両方）。「い」欠落ルールの前提は「stemに末尾のいが無い」ことなので、い終わりstemは定義上対象外。`少な→少ない` / `くださ→ください` の既存抑制は維持。
- **検証**: `AIRerankerTests` に「してほしい」が降格されない regression test、eval fixture に `incomplete-stem-sitehosii-garbage-001` を追加。
- **教訓**: 「候補集合内の別候補を根拠に penalize する」ルールは、根拠側の候補が正当であることを検証できない（studydictにはtypoが混入する）。ルールの言語的前提（い終わり語幹は既に完成形）を条件に明示することで、ゴミ根拠に対して頑健になる。
