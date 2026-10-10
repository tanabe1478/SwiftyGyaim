# ADR-035: 左文脈をコントローラ再生成をまたいで引き継ぐ

## Status

Accepted (2026-10-10)

## Decision

確定語の連結である左文脈（モデル採点・ContextDict に渡す `recentCommittedText`）を、確定のたびにプロセス内の `CommittedContextStore` へクライアントの bundle identifier をキーに記録する。新しく作られた `GyaimController` は `activateServer` で、同じ bundle の最終確定が `aiRerankFastContextCarryOverSeconds`（既定 300 秒、0 で無効、上限 3600）以内なら、そのテキストを自分の文脈の初期値にする。引き継いだ composition は `Commit outcome` / `Fast context accepted detail` の payload に `contextInherited=true` を付け、集計ツールの `modelEffect.byContextOrigin` で効果を分けて測れるようにする。

## Context

2026-10-01〜10 の dogfood ログ（確定 8,839 件）で、`GyaimController` は 1,887 回作り直されていた（Ghostty 793、Chrome 759、Slack 242。直前の確定からの間隔は中央値 14 秒、60 秒以内が 1,322 回）。文脈はコントローラのインスタンス変数だったため、作り直しのたびに空に戻り、全確定の 32% が新しいコントローラの 3 語目以内（文脈が 0〜2 語）で行われていた。

文脈の有無はモデルの寄与の符号を変える。

| 文脈の長さ | 件数 | heuristic のみの先頭一致 | モデル適用後 |
|---|---|---|---|
| 0 文字 | 646 | 0.817 | 0.794 |
| 1〜5 文字 | 1,080 | 0.851 | 0.894 |
| 6〜19 文字 | 1,572 | 0.824 | 0.883 |
| 20 文字以上 | 1,862 | 0.805 | 0.865 |

具体例: 10/07 16:04 に Chrome で「どちらのサービスを使っているか」と打った 15 秒後、フォーカス移動でコントローラが作り直され、続く `atteiru` の採点に渡った文脈は「が」の 1 文字だった。

## Consideration

- クライアントからカーソル前のテキストを `attributedSubstring(from:)` で読む: 最も正確だが、Chrome / Electron 系など多くのアプリが返さず、`selectedRange()` の信頼性もアプリ依存（imk-constraints.md 6）。確定語の連結で代用している現状と整合しないため、将来の補完手段として残す。
- bundle を問わない単一のストア: Ghostty と Chrome を往復すると別アプリの文脈が混ざる。bundle 別にした。
- 無期限に引き継ぐ: 数十分前の文脈は別の話題である可能性が高い。間隔の分布（300 秒以内が 1,694 / 1,887）から既定 300 秒とし、設定で調整できるようにした。
- 同じコントローラが長く生きた場合の文脈の扱い（現状は無期限に保持）は変更しない。この ADR は再生成で消える分だけを扱う。

## Consequences

- 新しいコントローラの最初の数語でもモデルに文脈が渡り、文脈なしでモデルが先頭を悪化させる経路（10 日間で 28 件の先頭取りこぼし）が減る見込み。効果は `contextInherited` 別の集計で確認する。
- 同じアプリ内で別の文書・入力欄に移った直後は、前の欄の文脈が 300 秒まで使われる。文脈なしより悪くなるかは未確認で、`byContextOrigin` の worsened で監視する。
- `CommittedContextStore` はメインスレッド専用。bundle が取れないクライアントでは従来どおり文脈は引き継がれない。

## References

- `GyaimSwift/Sources/Gyaim/CommittedContextStore.swift`
- `docs/specs/input-flow.md` 左文脈の寿命、`docs/specs/imk-constraints.md` 8
- ADR-020（文脈条件付き学習）、ADR-028（確定 payload）、ADR-032（LLM 主体の並べ替え）
