# BUG-021: `ha?` で長いlocal候補が `は？` より上位化する

- **発見日**: 2026-06-23
- **症状**: `ha?` 入力で `投機的デコーディング` が `は？` より上位になり、確定後に `ha?` の study/local 候補として残った。さらに `h` / `ha` の prefix 候補にも混入した。
- **影響**: 句読点つき短入力で、直前に誤登録された長いユーザー辞書候補が自然な句読点候補を押しのける。削除操作で study だけ消しても local に残ると復活する。
- **原因**: `kind=exact` かつ `reading == inputPat` の長い local 候補に exact reading bonus / source bias が強くかかり、句読点を含む自然候補 `は？` の小さな punctuation penalty を上回った。また候補削除は候補sourceに応じて study または local の片方だけを削除していた。
- **修正**: `inputPat` が `?` / `!` で終わる場合、対応する句読点を含まない候補に `punctuatedInputMismatchPenalty` を与える。候補削除UIでは `.study` / `.local` のどちらから見えた場合でも、同じ word/reading を study/local 両方から削除する。
- **検証**: `AIRerankerTests` に `ha?` で `は？` が `投機的デコーディング` より上位になる regression test を追加。`WordSearchTests` に `deleteFromUserDictionaries` が study/local 両方を削除するテストを追加。fast-context eval fixture に `ha?` ケースを追加。
- **教訓**: ユーザー辞書由来の exact 候補でも、句読点つき短入力では「句読点を含むか」を安全条件に含める。削除UIは表示sourceだけを信用せず、同一word/readingのユーザー管理辞書をまとめて掃除する。
