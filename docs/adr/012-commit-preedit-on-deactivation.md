# ADR-012: IME切替時に未確定テキストを確定する

## Status

Accepted

## Decision

`deactivateServer(_:)` で未確定テキスト（preedit）がある場合、破棄せずクライアントに確定（insertText）する。`fix(client:)` のクライアント解決に `self.client()` フォールバックを追加し、senderがnilでも確定できるようにする。

## Context

Gyaimで文字入力中（未確定状態）にIMEをoffに切り替えると、入力中のテキストが消えてしまう問題があった（Issue #13）。

原因は `deactivateServer(_:)` が `fix()` を引数なしで呼んでいたため、`fix(client:)` 内の `sender as? IMKTextInput` キャストが常に失敗し、`resetState()` でテキストが破棄されていたこと。

## Consideration

### 他IMEの挙動調査

| IME | deactivation時の未確定テキスト |
|-----|-------------------------------|
| Mozc / Google日本語入力 | 確定する（`switchModeToDirect:` → `commitText:`） |
| AzooKey | InputMethodKitサンプルパターンに従い確定 |
| ATOK | 確定する |

全ての主要日本語IMEは未確定テキストを確定する。破棄するIMEは確認できなかった。これはユーザーの入力を失わないという原則に基づく標準動作である。

### 設定トグルの要否

全IMEが確定を標準動作としているため、設定で無効化する必要はないと判断した。

### 修正方法

`fixAsKana()` で既に使われている `self.client()` フォールバックパターンを `fix(client:)` にも適用する。

```swift
// fixAsKana() (line 719) の既存パターン
let resolvedClient = (sender as? IMKTextInput) ?? (self.client() as? IMKTextInput)
```

## Consequences

- IME切替時に未確定テキストが確定され、ユーザーの入力が失われなくなる
- Mozc等の他IMEと同じ標準動作になり、ユーザーの期待に沿う
- `fix(client:)` が `self.client()` フォールバックを持つことで、sender引数がnilの他の呼び出し箇所でも堅牢になる

## References

- [Issue #13: Gyaim on/off時の挙動](https://github.com/tanabe1478/SwiftyGyaim/issues/13)
- [google/mozc - deactivateServer実装](https://github.com/google/mozc)
- [ensan-hcl/macOS_IMKitSample_2021](https://github.com/ensan-hcl/macOS_IMKitSample_2021)
