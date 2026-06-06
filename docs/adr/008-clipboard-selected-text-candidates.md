# ADR-008: クリップボード・選択テキスト候補の再実装

## Status

Accepted

## Decision

クリップボード内容と選択テキストをIME候補に表示する機能を再実装する。ClipboardMonitorによるポーリング方式でコピー時刻を追跡し、5秒以内のコピーのみ候補に表示する。両機能はUserDefaultsで個別にオン/オフ切り替え可能とする。候補順は raw input の直後、辞書検索結果の前に配置し、候補ウィンドウ上では外部候補が先頭に表示されるようにする。

## Context

ADR-002でフォーク元のクリップボード候補機能を一旦削除したが、ドッグフーディングの結果やはり便利であると判断し再実装することにした。フォーク元の実装には以下の問題があった：

- CopyText.timeのみに依存しており、IMEプロセス起動時にタイムスタンプが更新されるため5秒制限が機能しない
- 一度表示した候補が消えない（consumed状態の管理不備）
- 別のテキストをコピーしても最初のものが残り続ける

## Consideration

### クリップボード変更検知

| 方式 | メリット | デメリット |
|------|---------|-----------|
| CopyText.time のみ | 実装が単純 | IME起動時にタイムスタンプが上書きされ、5秒制限が無効化される |
| NSPasteboard.changeCount のみ | 新規コピーの検知が確実 | コピーの発生時刻がわからない |
| **ClipboardMonitor（採用）** | changeCount + 実時刻の両方を追跡 | 0.5秒間隔のポーリングが必要 |

ClipboardMonitorはGCDタイマーとRunLoopタイマーのデュアル方式で、IMEプロセス環境でも確実に動作する。

### 候補順

フォーク元 Gyaim の単語登録は、選択文字列を `inputPat` の直後に `unshift` し、候補ウィンドウでは第一候補として表示していた。SwiftyGyaim でもこの登録体験を維持するため、prefix mode の内部候補順は以下とする。

1. raw `inputPat`（Enter誤確定防止のため選択中候補として維持）
2. クリップボード候補（コピー後5秒以内）
3. 選択テキスト候補
4. 辞書検索結果
5. ひらがなフォールバック

候補ウィンドウは現在選択中の raw `inputPat` の次から表示するため、外部候補は表示上の先頭に出る。

### 消費状態の管理

| 方式 | メリット | デメリット |
|------|---------|-----------|
| インスタンス変数 `clipboardConsumed` | 単純 | GyaimControllerのインスタンス再生成で状態がリセットされる |
| **static変数 `lastConsumedCC`（採用）** | インスタンス再生成に耐える | なし |

### 設定のデフォルト値

UserDefaults.bool(forKey:)は未設定時にfalseを返すため、`object(forKey:) == nil` で未設定を検出しデフォルトtrueを返すパターンを採用。

## Consequences

### 良い点
- コピーから5秒以内の候補表示が正確に動作する
- 新しいコピーで前の候補が正しく消える
- ユーザーが不要な場合は設定画面からオフにできる
- 選択テキスト候補も同様にトグル可能

### 悪い点
- ClipboardMonitorが常時0.5秒間隔でポーリングする（CPU負荷は極小だが存在する）
- 選択テキスト候補はIMKTextInput経由で取得可能な範囲に限られる（既存ドキュメントのテキストは取得できない場合がある）

## References

- ADR-002: クリップボード候補機能の削除
- Apple: [NSPasteboard.changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/1533566-changecount)
