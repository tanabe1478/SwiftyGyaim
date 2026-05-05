# 入力・変換・確定フロー

## 中心ファイル

- `GyaimController.swift`
- `RomaKana.swift`
- `WordSearch.swift`
- `CandidateWindow.swift`
- `KeyBindings.swift`

`GyaimController.handle(_:client:)` が全キー入力の入口です。

## 状態モデル

```text
未入力
  │  通常文字入力
  ▼
変換中 inputPat != ""
  │
  ├─ 文字追加 / Backspace → 再検索
  ├─ Space → 候補選択 or 完全一致検索へ遷移
  ├─ Enter / 数字キー → 確定
  ├─ Escape → キャンセル
  ├─ F6 / ; → ひらがな確定
  ├─ F7 / q → カタカナ確定
  ├─ Googleトリガー → 非同期Google候補
  └─ Shift+X等 → 候補削除
```

## `handle(_:client:)` の処理順

概略は次の通りです。

1. `keyDown` 以外は処理しない
2. JISかな/英数キーは消費する
3. 変換中ショートカットを先に判定
   - ひらがな確定
   - カタカナ確定
   - Google変換
   - 候補削除
4. `event.characters` から1文字目を取得
5. 単キー確定 `;` / `q` を判定
6. Backspace / Escape / Space / Enter / 数字キー / 通常文字を処理

ショートカットが先に判定されるのは、通常入力として `inputPat` に入る前にアクションとして扱うためです。

## 通常文字入力

通常文字が来ると `inputPat` に追加し、`searchAndShowCands()` を呼びます。

```text
inputPat += typedCharacter
searchAndShowCands(client: sender)
```

`searchAndShowCands()` はおおむね以下を行います。

1. `WordSearch.search(query: inputPat, searchMode: searchMode)`
2. クリップボード候補・選択テキスト候補など外部候補を追加
3. `showCands()` で候補ウィンドウを更新
4. クライアントへ marked text を設定

## Space キー

Space は状態により意味が変わります。

| 状態 | 動作 |
|---|---|
| 未変換 | 通常スペースとしてアプリに渡す |
| 候補あり | `nthCand` を進め、候補ページを更新 |
| 候補なし/必要時 | `searchMode=1` の完全一致検索へ遷移 |

候補ウィンドウのページングは `CandidateDisplayMode.current.maxVisible` を使います。

## Enter / 数字キー確定

`fix(client:)` が候補を確定します。

- `nthCand` が候補範囲内ならその候補を確定
- 通常確定では `WordSearch.study()` を呼ぶ
- `insertText` で入力先へ挿入
- 状態リセットと候補ウィンドウ非表示

IME切替時の `deactivateServer` では `fix(client: sender, skipStudy: true)` を使います。ユーザーが明示的に選んでいないため学習しません。

## ひらがな / カタカナ確定

`fixAsKana(hiragana:client:)` で `inputPat` を `RomaKana` により変換します。

| 操作 | 実装 | 例 |
|---|---|---|
| F6 / `;` | `roma2hiragana` | `nihon` → `にほん` |
| F7 / `q` | `roma2katakana` | `nihon` → `ニホン` |

通常確定なので学習対象になります。ただし平仮名学習の設定がOFFなら、全ひらがな語は `WordSearch.study()` でスキップされます。

## Google変換

Google変換は2種類のトリガーがあります。

1. 入力末尾のサフィックス（デフォルト `` ` ``）
2. 設定されたショートカット

処理フロー:

```text
triggerGoogleTransliterate()
  ├─ query を確定
  ├─ pendingGoogleQuery = query
  ├─ GoogleTransliterate.searchCands(query) 非同期実行
  └─ callback
      ├─ pendingGoogleQuery が一致しなければ破棄
      ├─ Google候補 + かなfallback を SearchCandidate化
      ├─ searchMode = 2
      └─ showCands()
```

`pendingGoogleQuery` は、API応答待ちの間に入力が変わった場合に古い結果を捨てる stale guard です。

## Backspace / Escape

Backspace:

- 候補選択中なら `nthCand` を戻す
- そうでなければ `inputPat` 末尾を削除
- 空になれば状態リセット

Escape:

- `resetState()`
- marked text を消す
- 候補ウィンドウを隠す

## 候補削除

候補表示中に削除ショートカットを押すと `deleteCurrentCandidate(client:)` が呼ばれます。

削除可能なのは `SearchCandidate.source` が以下のものです。

- `.study`
- `.local`

削除不可:

- `.connection`
- `.external`
- `.synthetic`

削除後は再検索し、候補ウィンドウを更新します。

## marked text 更新

変換中はクライアントに未確定文字列を表示します。表示する文字列は基本的に `RomaKana.roma2hiragana(inputPat)` です。

```text
inputPat: "nihon"
marked text: "にほん"
```

候補選択中でも、入力先には未確定テキストがあり、候補ウィンドウで変換候補を選ぶ構成です。

## routeEvent との関係

過去の設計で、キー入力分岐の一部は副作用なしでテスト可能な `routeEvent` として抽出されています。`HandleEventTests` はこの分岐ロジックを広くカバーします。

ただし実際の `handle(_:client:)` は、ショートカット、クライアント操作、候補表示、辞書学習など副作用を伴うため、`routeEvent` と完全に同一ではありません。

## 重要な注意点

- `deactivateServer` では必ず未確定文字列を確定する
- deactivation確定では学習しない
- `sender` が不正でも `self.client()` でフォールバックする
- Google結果は非同期なので stale guard が必須
- 候補削除は `CandidateSource` の整合性に依存する
