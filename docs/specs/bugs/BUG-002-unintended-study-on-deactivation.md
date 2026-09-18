# BUG-002: deactivation確定でstudyDictに意図しない登録

- **Issue**: #13 (follow-up)
- **発見日**: 2026-03-17
- **影響**: IME切替時の自動確定でローマ字がそのまま学習辞書に登録され、次回入力時に不要な候補が出現
- **原因**: `fix()` が常に `ws?.study()` を呼んでいた
- **修正**: `fix(client:skipStudy:)` パラメータ追加、deactivation時は `skipStudy: true`
- **教訓**: ユーザーが意図的に選択していない確定では学習しないこと
- **関連PR**: #18
