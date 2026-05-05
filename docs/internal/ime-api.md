# Swift / InputMethodKit で作る IME の概要

## InputMethodKit の基本構造

macOS の IME は InputMethodKit を使って実装できます。SwiftyGyaim では以下のクラス/APIが中心です。

| API | SwiftyGyaimでの使い方 |
|---|---|
| `IMKServer` | `main.swift` で1つ作成し、IMEサーバとして起動 |
| `IMKInputController` | `GyaimController` が継承。キーイベント・ライフサイクルを処理 |
| `IMKTextInput` | 入力先アプリへの marked text / committed text の反映に使う |
| `NSEvent` | `handle(_:client:)` に渡されるキーイベント |
| `NSPanel` | 候補ウィンドウを非アクティブに表示 |

## 起動

`main.swift` は非常に小さく、`IMKServer` を作って `NSApplication` を実行します。

```swift
let server = IMKServer(name: "Gyaim_Connection",
                       bundleIdentifier: Bundle.main.bundleIdentifier!)

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
```

`name` は `Resources/Info.plist` の `InputMethodConnectionName` と対応します。ここがずれると macOS 側から IME サーバに接続できません。

## Info.plist の役割

IMEとして認識されるには、通常アプリとは異なるキーが必要です。

代表例:

| キー | 意味 |
|---|---|
| `InputMethodConnectionName` | `IMKServer` の connection name |
| `InputMethodServerControllerClass` | `IMKInputController` サブクラス名 |
| `InputMethodServerDelegateClass` | delegate class名 |
| `LSBackgroundOnly` | バックグラウンドアプリとして動作 |
| `ComponentInputModeDict` | 入力ソースとしての定義 |

SwiftyGyaim のアプリ識別子は `com.pitecan.inputmethod.SwiftyGyaim` です。

## IMKInputController のライフサイクル

`GyaimController` は `IMKInputController` を継承します。

主な override:

| メソッド | 呼ばれるタイミング | 実装内容 |
|---|---|---|
| `init(server:delegate:client:)` | controller生成時 | 候補ウィンドウ、辞書、状態初期化 |
| `activateServer(_:)` | IMEが有効化された時 | 辞書start、クリップボード取得、候補表示更新 |
| `deactivateServer(_:)` | IMEが無効化された時 | 未確定テキストを確定、辞書finish |
| `handle(_:client:)` | キー入力時 | 入力処理の中心 |
| `menu()` | 入力メニュー表示時 | 設定・辞書エディタメニューを返す |
| `showPreferences(_:)` | 設定表示 | `PreferencesWindow.show()` |

## 入力先アプリとのやり取り

入力先アプリは `IMKTextInput` として渡されます。SwiftyGyaim では主に以下を使います。

| メソッド | 用途 |
|---|---|
| `setMarkedText(_:selectionRange:replacementRange:)` | 未確定テキストを表示 |
| `insertText(_:replacementRange:)` | 確定テキストを挿入 |
| `attributes(forCharacterIndex:lineHeightRectangle:)` | キャレット行矩形を取得し候補ウィンドウ位置に使う |
| `selectedRange()` / `attributedSubstring(from:)` | 選択テキスト候補の取得に使う |

### marked text と committed text

IMEは通常、入力中の文字を「未確定テキスト」として表示し、Enterや候補選択で「確定テキスト」として挿入します。

```text
入力中:
  setMarkedText("かな", ...)

確定:
  insertText("仮名", ...)
```

`insertText` を呼ぶと、多くのクライアントでは marked text は自動的に消えます。

## クライアント取得の注意

`deactivateServer(_:)` などライフサイクルメソッドでは `sender` が常に `IMKTextInput` とは限りません。そのため SwiftyGyaim では次のパターンを使います。

```swift
let resolvedClient = (sender as? IMKTextInput) ?? (self.client() as? IMKTextInput)
```

これは過去に「IME切替時に未確定テキストが消える」バグを防ぐための重要パターンです。

## 候補ウィンドウ位置API

候補ウィンドウは `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` で得た `lineRect` を基準に表示します。

```swift
var lineRect = NSRect.zero
client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
```

ただし一部のWebアプリはスクリーン座標ではなくローカル座標を返すことがあります。そのため現在は `CandidateWindowPositioner.resolveLineRect()` で妥当性を検証し、前回正常値やマウス位置へフォールバックします。

## NSApplication activation policy

SwiftyGyaim は `LSBackgroundOnly` なので通常は前面アプリになりません。

- 候補ウィンドウ: `orderFront(nil)` のみ。アプリをアクティブ化しない
- 設定画面/辞書エディタ: 一時的に `.accessory`
- 閉じる時: `.prohibited`

```swift
NSApp.setActivationPolicy(.accessory)
NSApp.activate(ignoringOtherApps: true)
```

## ターミナルの Ctrl+key 問題

Terminal.app や iTerm2 は Ctrl+key を IME より先に処理する場合があります。そのため SwiftyGyaim では、Ctrl+Shift+U などの修飾キーショートカットに加えて、`;` や `q` の単キー確定も用意しています。

## InputMethodKit 実装時の設計方針

1. 入力先アプリのフォーカスを奪わない
2. `sender` を過信せず `self.client()` でフォールバックする
3. クライアントが返す座標・選択範囲は信用しすぎない
4. ライフサイクルメソッドではテキスト消失を最優先で防ぐ
5. 複数 `GyaimController` インスタンスを前提に共有状態を設計する
