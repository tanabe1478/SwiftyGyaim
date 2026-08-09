# ADR-023: 非表示のASCII対応英数モードによるSecure Event Input縮退

## Status

Accepted

## Decision

`Info.plist` の `ComponentInputModeDict` にASCII対応の英数モード `com.apple.inputmethod.Roman`（`smRoman`、言語 `en`、`TISInputSourceID = com.pitecan.inputmethod.SwiftyGyaim.Roman`）を追加する。ただし `tsInputModeIsVisibleKey = false` とし、`tsVisibleInputModeOrderedArrayKey` にも載せず、入力メニューからは見えないフォールバック専用モードとする。

- 非表示モードはシステム設定から有効化できないため、`AppDelegate.applicationDidFinishLaunching` で `TISEnableInputSource` により自動有効化する
- `GyaimController.setValue(_:forTag:client:)` で `kTextServiceInputModePropertyTag` を受け、Romanモードでは `handle(_:client:)` が即座に `false` を返して全キーをクライアントへパススルーする
- Romanモードへの切替時、未確定入力があれば `fix(client:sender, skipStudy: true)` で確定してから移行する

## Context

macOSのSecure Event Input（パスワード入力保護）が有効な間、システムはASCII対応の入力ソースしか選択を許可しない。Secure Inputの所有プロセスが終了してもWindowServerにPIDが残留するmacOS側の不具合（issue #85）が起きると、この制限が解除されず、SwiftyGyaimは入力メニューでグレーアウトして選択不能のままになる。

純正日本語IM（Kotoeri）やGoogle日本語入力はASCII対応の英字モードを持つため、Secure Input中はIME内の英字モードへ縮退し、解除後に日本語モードへ自然復帰する。SwiftyGyaimは日本語モード1つしか登録していなかったため、IME全体が選択不能になり症状が際立っていた。

## Consideration

1. **英数モードを可視で追加（Kotoeri方式）** — 標準的だが、入力メニューに「英字」が増えユーザーの認知負荷になる。ユーザーは英数モードの存在を意識させない方針を希望
2. **英数モードを非表示で追加（採用）** — メニューには従来どおり「Gyaim」1つだけが見える。非表示モードはシステム設定で有効化できないため、起動時の `TISEnableInputSource` が必須。実機検証で `ASCIICapable=true / enabled=true / selectCapable=true` として登録されることを確認済み
3. **Secure Input検出・診断ログのみ（issue #85の当初案）** — 原因の可視化はできるが症状自体は回避できない。将来の追加改善として残す

なお `TISCreateASCIICapableInputSourceList` はキーボードレイアウトのみを返すため（実機でKotoeri英字モード有効時も `com.apple.keylayout.ABC` のみ）、Secure Input中の実際の縮退挙動の最終確認はTerminalの「安全なキーボード入力」等での実機観察による。自プロセスがSecure Input所有者の場合は選択制限を再現できないことも確認した。

## Consequences

- 良い点: Secure Input発動中・残留時もGyaimがASCII対応モードを持つため、IME全体のグレーアウトを回避できる余地が生まれる。メニュー上のUXは従来と変わらない
- 良い点: Romanモードはパススルーのみで変換ロジックに影響しない。未知のモードIDは `.japanese` にフォールバックし、パススルーに固着しない
- 悪い点: 非表示モードの自動有効化はTISの公開APIだが、モード非表示×プログラム的enableの組合せはOSアップデートで挙動が変わるリスクがある
- 悪い点: Secure Input残留という根本原因（macOS/所有アプリ側のバグ）自体は解決しない。検出・診断ログ（issue #85の残タスク）は別途必要

## References

- Issue #85: Secure Event Input残留時に原因を診断し復旧方法を案内する
- macSKKでの類似症状: https://github.com/mtgto/macSKK/issues/112
- mac-akazaでの調査記事: https://blog.64p.org/entry/2026/07/13/044753
