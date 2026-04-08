# ADR-015: 候補表示中のユーザー辞書エントリ削除

## Status

Accepted

## Decision

候補表示中にShift+X（大文字X）を押すことで、選択中の候補が学習辞書またはユーザー辞書のエントリであれば即座に削除する。接続辞書・外部候補・合成候補は削除不可。

## Context

誤変換を確定すると学習辞書に不要なエントリが登録され、以降の変換で不要な候補が表示され続ける。ユーザー辞書エディタ（DictEditorWindow）で手動削除は可能だが、変換フロー中にインラインで削除できる方が効率的。

Aqua SKKではXキーをRemoveTriggerとして候補削除に使用しており、SwiftyGyaimの既存ショートカット（`;`=ひらがな、`q`=カタカナ）もAqua SKKインスパイアであるため、同様のアプローチを採用する。

## Consideration

### トリガーキーの選択

| 選択肢 | 利点 | 欠点 |
|--------|------|------|
| 素のXキー（Aqua SKK準拠） | Aqua SKKユーザーに馴染みやすい | xはローマ字入力で使用（xa=ぁ等）。候補表示中にx始まりの入力ができなくなる |
| Shift+X（大文字X） | 誤爆しにくい。候補表示中のみ発動 | Shift押下が必要 |
| Ctrl+X | 修飾キーで明確 | ターミナルアプリでCtrl+Xが横取りされる可能性 |

**Shift+X**を採用。候補表示中（`nthCand > 0 || searchMode > 0`）のみ発動し、通常入力時はスルーされる。KeyBindingsで設定可能。

### CandidateSourceの追跡

SearchCandidateに`source: CandidateSource`フィールドを追加し、各候補の出自を記録する。これにより削除可能かどうかを正確に判定できる。

| ソース | 削除可否 | 説明 |
|--------|----------|------|
| `.study` | 可能 | 学習辞書 |
| `.local` | 可能 | ユーザー辞書 |
| `.connection` | 不可 | 接続辞書（読み取り専用） |
| `.external` | 不可 | クリップボード/選択テキスト |
| `.synthetic` | 不可 | inputPat/ひらがな/タイムスタンプ等 |

### 確認ダイアログ

Aqua SKKに倣い、確認なしで即削除とする。学習辞書は自動学習されたものなので削除のリスクは低い。

## Consequences

- 変換フロー中に不要な候補を即座に削除できるようになる
- SearchCandidateにsourceフィールドが追加されるが、デフォルト値（`.synthetic`）により後方互換性を維持
- routeEventのパラメータが2つ増加（`matchesDeleteCandidateShortcut`, `deleteCandidateChar`）

## References

- [Aqua SKK keymap.conf](https://github.com/codefirst/aquaskk/blob/master/data/config/keymap.conf) — RemoveTrigger
- ADR-009: routeEvent抽出とテスト戦略
- ADR-014: スコアベース学習辞書淘汰
