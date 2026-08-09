# Spec: InputMethodKit制約集

> Trigger: GyaimController.swift, AppDelegate.swift, main.swift, CandidateWindow.swift
> Last updated: 2026-08-09 (Secure Event Input対策の非表示英数モード — ADR-023)

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

### 9. Secure Event Input と ASCII対応入力モード（ADR-023）

Secure Event Input（パスワード保護）が有効な間、macOSはASCII対応入力ソースしか選択を許可しない。所有プロセス終了後もWindowServerにPIDが残留するOS側バグ（issue #85）があり、その間ASCII対応モードを持たないIMEは入力メニューでグレーアウトし選択不能になる。

対策として `Info.plist` に非表示（`tsInputModeIsVisibleKey=false`）のASCII対応英数モード `com.apple.inputmethod.Roman` を登録している。

- 非表示モードはシステム設定から有効化できないため、`AppDelegate` 起動時に `TISEnableInputSource` で自動有効化する
- モード切替は `GyaimController.setValue(_:forTag:client:)`（`kTextServiceInputModePropertyTag`）で受け、Romanモード中は `handle` が `false` を返して全キーパススルー
- Romanモード切替時に未確定入力があれば `fix(skipStudy: true)` で確定してから移行
- 他プロセスが所有するSecure Inputは `DisableSecureEventInput()` で解除できない（自プロセスのカウンタにのみ作用）
- 残留診断: `ioreg -l -w 0 | grep -o 'kCGSSessionSecureInputPID"=[0-9]*'`、復旧は所有アプリの完全終了→ダメなら `Ctrl+Cmd+Q` 画面ロック・解除
