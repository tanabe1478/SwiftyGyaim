# BUG-018: 途中入力で polite negative 候補が先頭化する

- **発見日**: 2026-06-19
- **症状**: dogfood log で `onegaisim` の `お願いします -> お願いしません`、`omoim` の `おもいます -> 思いません` のように、`masen` まで入力していない段階で polite negative 候補が第一候補になる。
- **影響**: 肯定・依頼表現を入力している途中で否定表現が先頭化し、Enter 確定時に意味が反転する可能性がある。
- **原因**: 学習済み候補や prefix 候補の metadata によっては、`〜ません` が exact / 高スコア候補として扱われ、prefix penalty だけでは `お願いします` / `思います` 系を守りきれない。
- **修正**: `masen` / `masenn` が inputPat に含まれず、左文脈にも否定 cue がない場合、`ません` / `ませんか` / `ません？` / `ませんか？` で終わる候補へ `politeNegativePredictionPenalty` を与える。Python offline evaluator にも同じ feature を追加し、dogfood 由来 fixture を2件追加。
- **検証**: `AIRerankerTests` に premature polite negative の抑制と、`masen` まで明示入力した場合は抑制しないテストを追加。fast-context eval fixture は 107件で top1 `107/107`。
- **教訓**: 通常入力中の prefix prediction では、長い候補が「文法的にあり得る」だけでは先頭にしない。特に否定・依頼・疑問など意味を反転させる接尾表現は、入力文字列または左文脈で明示されるまで保守的に扱う。
