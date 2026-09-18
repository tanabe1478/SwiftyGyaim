# BUG-019: 設定画面で標準Commandショートカットが効かない

- **発見日**: 2026-06-19
- **症状**: 設定画面で他のmacOSアプリでは効く `Cmd+W` や `Cmd+V` が効かない。
- **影響**: 設定画面をキーボードで閉じられず、URL入力欄などへの paste もできないため、通常のmacOSアプリとしての操作感を損なう。
- **原因**: IMEは `LSBackgroundOnly` で動作し、設定画面表示時だけ `.accessory` に切り替える。通常アプリのようなメインメニュー / Editメニューを持たないため、Command key equivalent が標準メニューアクションとして解決されず、`keyDown` override だけでは `Cmd+W` / `Cmd+V` を安定して受けられない。
- **修正**: `PreferencesWindow.performKeyEquivalent(with:)` で `Cmd+W` を直接処理し、`Cmd+X/C/V/A/Z` と `Shift+Cmd+Z` は `NSApp.sendAction` で first responder へ標準 text / undo action として送る。
- **検証**: `PreferencesWindowTests` に `Cmd+W` が window を閉じること、`Cmd+V` が first responder の `paste(_:)` に dispatch されることを確認するテストを追加。
- **教訓**: `LSBackgroundOnly` なIMEが一時的に設定画面を出す場合、通常アプリのメニュー由来ショートカットを前提にしない。`keyDown` ではなく `performKeyEquivalent` または明示的なメニュー構築で標準Command操作を補う。
