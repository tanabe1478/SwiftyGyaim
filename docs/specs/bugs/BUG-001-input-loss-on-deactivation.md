# BUG-001: deactivation時に未確定テキストが消える

- **Issue**: #13
- **発見日**: 2026-03-17
- **影響**: IME切替時にユーザーの入力が消失
- **原因**: `deactivateServer(_:)` が `fix()` を引数なしで呼び、`sender as? IMKTextInput` が常に失敗
- **修正**: `fix(client: sender)` でsenderを渡す + `self.client()` フォールバック追加
- **教訓**: IMKTextInputのクライアント取得は必ず `self.client()` フォールバックを入れること
- **関連ADR**: ADR-012
