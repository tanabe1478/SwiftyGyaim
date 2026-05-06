# Swift / InputMethodKit で作る IME の概要

このドキュメントでは、Swift/AppKit開発者向けに、macOS IME を作る時に出てくるAPIと、SwiftyGyaimでの具体的な使い方を説明します。

## 1. 通常のmacOSアプリとの違い

IMEも `.app` ですが、ユーザーがDockから起動してウィンドウを操作するタイプのアプリではありません。入力ソースとしてmacOSに登録され、選択された時にキーイベントを受け取ります。

SwiftyGyaimの `Info.plist` には、通常アプリに加えてIME用のキーが入っています。

| キー | 役割 |
|---|---|
| `InputMethodConnectionName` | `IMKServer` の名前 |
| `InputMethodServerControllerClass` | `IMKInputController` サブクラス名 |
| `InputMethodServerDelegateClass` | delegate class名 |
| `ComponentInputModeDict` | 入力ソース定義 |
| `LSBackgroundOnly` | バックグラウンドプロセスとして動作 |

`LSBackgroundOnly` があるため、普通のCocoaアプリのように前面化するとフォーカス問題が起きます。

## 2. `IMKServer`

`main.swift` では `IMKServer` を作ります。

```swift
let server = IMKServer(name: "Gyaim_Connection",
                       bundleIdentifier: Bundle.main.bundleIdentifier!)
```

この `name` は `Info.plist` の `InputMethodConnectionName` と一致している必要があります。

`IMKServer` は、macOSの入力メソッド機構とアプリプロセスを接続するサーバです。Swiftコードから直接メソッドを呼び続けるというより、作ってrun loopに入ると、InputMethodKitがcontrollerを生成してイベントを配送します。

## 3. `IMKInputController`

IMEの中核は `IMKInputController` のサブクラスです。

```swift
@objc(GyaimController)
class GyaimController: IMKInputController {
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool { ... }
}
```

`@objc(GyaimController)` は重要です。`Info.plist` からObjective-C runtime経由で参照されるため、Swiftのmodule名に依存しない名前を付けています。

## 4. `init(server:delegate:client:)`

```swift
override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
    super.init(server: server, delegate: delegate, client: inputClient)
    ...
}
```

`client` は入力先アプリを表します。ただし型は `Any!` です。実際にテキスト操作する時は `IMKTextInput` にcastします。

```swift
if let client = inputClient as? (IMKTextInput & NSObjectProtocol) {
    CopyText.set(NSPasteboard.general.string(forType: .string))
}
```

SwiftyGyaimではこのinitで候補ウィンドウと辞書を初期化します。

## 5. `activateServer` / `deactivateServer`

```swift
override func activateServer(_ sender: Any!) {
    CopyText.set(NSPasteboard.general.string(forType: .string))
    ws?.start()
    showWindow()
}
```

IMEが有効になった時に呼ばれます。辞書の開始処理やクリップボード更新を行います。

```swift
override func deactivateServer(_ sender: Any!) {
    hideWindow()
    fix(client: sender, skipStudy: true)
    ws?.finish()
}
```

IMEが無効になった時は、未確定テキストを確定します。これはMozc/Google日本語入力などと同じく、IME切替で入力が消えないようにするためです。

`skipStudy: true` が重要です。IME切替による自動確定はユーザーが候補を選んだわけではないので、学習辞書には入れません。

## 6. `handle(_:client:)`

キー入力イベントの入口です。

```swift
override func handle(_ event: NSEvent!, client sender: Any!) -> Bool
```

- `event`: `NSEvent`。キーコード、文字、修飾キーを持つ
- `sender`: 入力先クライアント。多くの場合 `IMKTextInput`
- 戻り値: IMEが処理したら `true`

SwiftyGyaimではASCII文字を中心に処理します。

```swift
guard let eventString = event.characters, !eventString.isEmpty else { return true }
guard let c = eventString.utf8.first else { return true }
```

`NSEvent.keyCode` は物理キー、`event.characters` は修飾キーを反映した文字です。ショートカットの信頼性を上げるため、`KeyShortcut` は `keyCode` と `charCode` の両方を持ちます。

## 7. `IMKTextInput`

入力先アプリとのやり取りは `IMKTextInput` で行います。

### 未確定テキスト

```swift
client.setMarkedText(attrStr,
    selectionRange: NSRange(location: word.count, length: 0),
    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
```

`setMarkedText` は、入力中の下線付きテキストを更新します。`selectionRange` はmarked text内のカーソル位置です。

### 確定テキスト

```swift
client.insertText(word,
    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
```

`insertText` で確定文字列を挿入します。通常、marked text はこれで消えます。

### キャレット位置

```swift
var reportedLineRect = NSRect.zero
client.attributes(forCharacterIndex: 0, lineHeightRectangle: &reportedLineRect)
```

候補ウィンドウ位置に使う矩形を取得します。ただし、これはクライアント実装依存です。WebView系ではスクリーン座標でない値が返ることがあるため、SwiftyGyaimでは妥当性検証を挟みます。

### 選択テキスト

```swift
let range = client.selectedRange()
if range.length > 0 {
    let attrStr = client.attributedSubstring(from: range)
}
```

選択テキスト候補のために使います。アプリによって `NSNotFound` や不正なrangeを返すことがあるので、防御的に扱います。

## 8. `sender` を信用しすぎない

InputMethodKit の罠として、`deactivateServer(_:)` などで渡ってくる `sender` が期待通りの `IMKTextInput` でないことがあります。

そのため確定処理では必ずfallbackします。

```swift
let resolvedClient = (sender as? IMKTextInput) ?? (self.client() as? IMKTextInput)
```

`self.client()` は `IMKInputController` が保持しているクライアントです。これを使わないと、IME切替時に未確定テキストが消えるバグになります。

## 9. 候補ウィンドウで使う AppKit API

候補ウィンドウは `NSPanel` です。

```swift
styleMask: [.borderless, .nonactivatingPanel]
```

`orderFront(nil)` で表示し、`NSApp.activate` はしません。

```swift
cw.setFrameOrigin(origin)
cw.orderFront(nil)
```

設定画面や辞書エディタは入力先からフォーカスを移してよいUIなので、一時的にactivation policyを変えます。

```swift
NSApp.setActivationPolicy(.accessory)
NSApp.activate(ignoringOtherApps: true)
```

閉じる時は `.prohibited` に戻します。

## 10. IME開発で起きやすい問題

### フォーカスを奪う

通常の `NSWindow` を表示したり `NSApp.unhide(nil)` を呼ぶと、入力先アプリがフォーカスを失うことがあります。候補ウィンドウでは絶対に避けます。

### クライアント座標が信用できない

`lineRect` や `selectedRange` はアプリ依存です。取得に成功しても意味が正しいとは限りません。

### controllerが複数できる

クライアントごとに `GyaimController` が生成され得ます。学習辞書のような共有状態はstaticや外部保存を含めて設計します。

### ターミナルがCtrlキーを奪う

Terminal.app/iTerm2では Ctrl+key がIMEに届かないことがあります。SwiftyGyaimでは `;` / `q` など単キー操作を併用しています。

## 11. Swift実装としての特徴

- InputMethodKitはObjective-C由来APIなので `Any!` やIUOが多い
- `@objc` 名、Info.plist、runtime参照の整合が必要
- `NSRange(location: NSNotFound, length: NSNotFound)` のようなCocoa慣習が残る
- UIはAppKitでコード生成しており、SwiftUIは使っていない
- 非同期Google変換は `URLSession` → main queue callback でUI更新する
