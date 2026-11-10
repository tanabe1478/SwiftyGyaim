# BUG-048: 子音だけの状態でかな確定すると、下線付きの文字が残って消せない

- **Issue**: なし（dogfood の報告「直前の入力が消せない」）
- **発見日**: 2026-11-06
- **影響**: `k` や `kljf` のように、まだかなになっていないローマ字だけの状態でひらがな確定（`;` / F6）またはカタカナ確定（`q` / F7）を押すと、IME は変換を終えた扱いになるのに、アプリ側には下線付きの `kljf` が残る。IME はもう変換中ではないので Backspace は IME を素通りし、残った文字も消せない。次の文字を打つと新しい未確定テキストで上書きされて消える。
- **原因**: `fixAsKana` は `roma2hiragana` の結果が空文字のとき `resetState()` と `hideWindow()` だけで戻っていた。通常の確定は `insertText` がマーク済みテキストを消してくれるが（imk-constraints.md 7）、空文字では `insertText` を呼ばないため、`setMarkedText` で表示した未確定テキストがクライアントに残ったままになる。`fix()` の `nthCand >= candidates.count` の分岐にも同じ漏れがあった。
- **修正**: `clearMarkedText(client:)` を足し、`insertText` を呼ばずに変換を終える 2 つの分岐で空の `setMarkedText` を送ってから状態をリセットする。
- **検証**: `KanaConfirmMarkedTextTests.testKanaConfirmOnConsonantsClearsMarkedText`（`GyaimController(server: nil, delegate: nil, client: nil)` に `MockIMKTextInput` を送信元として `k` `l` `j` `f` `;` を流し、挿入なし・最後のマーク済みテキストが空・その後の Backspace が素通りすること）。修正前のコントローラでは最後のマーク済みテキストが nil で失敗する。TextEdit での E2E は、テストプロセスから TextEdit を前面にできずキー入力が書類に届かなかったため採用していない。
- **教訓**: 変換を終える経路は「`insertText` を呼ぶ」か「マーク済みテキストを明示的に空にする」のどちらかを必ず通す。状態だけ戻してもクライアントの表示は戻らない。
- **関連ADR / PR**: imk-constraints.md 7（setMarkedText / insertText の順序）
