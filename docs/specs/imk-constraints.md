# Spec: InputMethodKit制約集

> Trigger: GyaimController.swift, AppDelegate.swift, main.swift, CandidateWindow.swift
> Last updated: 2026-03-17

## 概要

macOS InputMethodKitフレームワーク固有の制約と回避策。IME開発で繰り返し遭遇するハマりポイントを集約。

## 制約一覧

### 1. LSBackgroundOnly

IMEアプリは `LSBackgroundOnly = true` で動作する。

- `NSApp.unhide(nil)` を呼ぶとフォーカスを失う → **使用禁止**
- ウィンドウ表示は `orderFront(nil)` のみ（ADR-005）
- 設定画面やエディタを開くときは `NSApp.setActivationPolicy(.accessory)` を一時的に設定し、閉じたら `.prohibited` に戻す

### 2. NSPanel (非アクティブウィンドウ)

候補ウィンドウはNSPanelの `.nonactivatingPanel` スタイルが必須（ADR-006）。通常のNSWindowだとIMEがフォーカスを奪い、入力先アプリからフォーカスが外れる。

### 3. Ctrl+key のターミナルでの動作

ターミナルアプリ（Terminal.app, iTerm2等）はCtrl+keyをIMEより先にインターセプトする。IME側のCtrl+keyショートカットは届かない場合がある。回避策: single-key shortcuts（`;`、`q`）を併用。

### 4. deactivateServerのsender

`deactivateServer(_:)` の `sender` 引数はクライアント（IMKTextInput）だが、nil や非IMKTextInputの場合がある。**必ず `self.client()` フォールバックを使うこと**。

```swift
// 正しいパターン（fixAsKana, fix共通）
let resolvedClient = (sender as? IMKTextInput) ?? (self.client() as? IMKTextInput)
```

### 5. メニューバーアイコン

20x20 PDF形式が必須。Retina対応のためPNGではなくPDFを使用。

### 6. IMKTextInputのselectedRange

`client.selectedRange()` はアプリによって信頼性が異なる。一部アプリではNSNotFoundを返す。

### 7. setMarkedText / insertText の順序

`setMarkedText` で下線付きテキストを表示し、`insertText` で確定する。`insertText` を呼ぶとmarked textは自動的にクリアされる。

### 8. IMKServer のシングルトン

`main.swift` で作成する `IMKServer` はアプリのライフタイム中1つだけ。GyaimControllerのインスタンスは入力ソースの切り替えごとに再生成される可能性がある。staticプロパティ（`lastConsumedCC`等）はこのため必要。
