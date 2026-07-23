# ADR-012: IME deactivation確定のTLA+モデル

## 目的

`GyaimController.deactivateServer(_:)` の次の実行順を最小の状態機械として表し、IME切替時に未確定入力を失ったBUG-001の反例と、現行実装の安全性をTLCで検査する。

```text
hideWindow() → fix(client: sender, skipStudy: true) → ws?.finish()
```

## 検査する性質

| 不変条件 | 意味 |
|---|---|
| `NoInputLoss` | senderまたは`self.client()`が利用可能なら、fix完了後にpreeditが確定済みである |
| `NoUnintentionalStudy` | IME切替による確定では学習しない |
| `WindowHiddenBeforeFix` | fix完了前に候補ウィンドウを隠す |
| `ResourcesFinishAfterFix` | 辞書リソースの終了はfix完了後だけに行う |
| `AtMostOneCommit` | 1回のdeactivationで重複確定しない |

`clientScenario` は次のInputMethodKit環境差を表す。

- `sender`: `deactivateServer(_:)` のsenderだけが有効な`IMKTextInput`
- `fallback`: senderは無効だが`self.client()`は有効
- `both`: 両方が有効
- `none`: どちらからもクライアントを取得できない

`none` の場合は挿入先自体がないため、`NoInputLoss`の保証対象外とする。現行Swift実装も状態をリセットするが、テキストを挿入できたとはみなさない。

## モデルと実装の対応

| 設定 | 対応する実装 | 期待結果 |
|---|---|---|
| `Historical.cfg` | 修正前: `deactivateServer`がsenderを`fix()`へ渡さず、fallbackもない | `NoInputLoss`違反 |
| `Current.cfg` | 現行: senderを渡し、失敗時は`self.client()`へfallbackし、`skipStudy: true` | 全不変条件を満たす |

Historicalモデルでは、環境から有効なsenderが渡されているにもかかわらず、`fix()`へ引き継がれない。`FixComposition`後に `preedit = FALSE`、`committed = FALSE` となる反例が、Issue #13で観測された入力消失に対応する。

## TLCで検査する

TLA+ tools 1.8.0を使う例:

```bash
cd /absolute/path/to/SwiftyGyaim/docs/formal/deactivation
curl -fL -o /tmp/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
java -jar /tmp/tla2tools.jar -noGenerateSpecTE \
  -metadir /tmp/tlc-deactivation-historical \
  -config Historical.cfg DeactivationCommit.tla
java -jar /tmp/tla2tools.jar -noGenerateSpecTE \
  -metadir /tmp/tlc-deactivation-current \
  -config Current.cfg DeactivationCommit.tla
```

期待結果:

- `Historical.cfg`: `Invariant NoInputLoss is violated.`（期待する非zero終了）
- `Current.cfg`: `Model checking completed. No error has been found.`

`-metadir`と`-noGenerateSpecTE`によりTLC生成物を作業ツリーへ残さない。

## モデルの境界

このモデルはdeactivation 1回の制御順序とクライアント解決だけを扱う。次は抽象化している。

- 候補の選択規則、文字列内容、`insertText`自体のクライアント別挙動
- `hideWindow`、`insertText`、`finish`内部の例外やプロセスクラッシュ
- activate/deactivateの複数サイクルや非同期Google/AI候補更新
- クライアントが取得不能な場合のpreedit救済（挿入先がないため保証対象外）

## 関連資料

- `docs/adr/012-commit-preedit-on-deactivation.md`
- `docs/specs/input-flow.md` — IMEライフサイクルとdeactivation確定
- `docs/specs/imk-constraints.md` — senderと`self.client()` fallback
- `docs/specs/bug-memory.md` — BUG-001 / BUG-002
- Issue #13
