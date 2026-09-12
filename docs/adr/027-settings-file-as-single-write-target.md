# ADR-027: settings.json を唯一の設定書き込み先にする

## Status

Accepted

## Decision

`GyaimSettings.set` / `removeObject` は `~/.gyaim/settings.json` だけを更新し、UserDefaults へは書かない。読み取りは settings.json を優先し、値が無いときだけ UserDefaults を後方互換 fallback として読む。起動時の移行は UserDefaults → settings.json の一方向のみ。全キーは `GyaimSettings.knownKeys` と `docs/specs/settings.md` に列挙し、ソース中のキー文字列との一致をテストで検査する。

## Context

settings.json 導入後も `set` は両方に書き、`synchronizeFileAndUserDefaults` はファイルの値を UserDefaults にも書き戻していた。「どちらが正か」が決まっておらず、`knownKeys` には使われていないキーが 4 つ残り、実際に使われているキーが 11 個漏れていた。docs も一部が「UserDefaults キー」のまま。

## Consideration

- UserDefaults を完全に切る（読み取りも）: 旧バージョンから直接上げたユーザーの設定が消える。1 バージョンは fallback 読み取りを残す。
- テストの隔離: XCTest 実行中はこれまで UserDefaults にだけ書いていた。この挙動は維持し、`settingsFilePathOverride` を設定したテストだけがファイル経路を検証する。テスト側の 14 箇所の `UserDefaults.standard.set` による設定はそのまま動く。

## Consequences

- `defaults read com.pitecan.inputmethod.SwiftyGyaim` は更新されなくなる。設定の確認は settings.json を見る。
- 旧バージョンへ戻した場合、そのバージョンも settings.json を先に読むため影響はない。
- 使われていない旧キーは移行対象から外した。旧 UserDefaults に残っていても読まれない。
- fallback 読み取りの撤去は次のメジャー更新で判断する。

## References

- docs/specs/settings.md
- BUG-027（設定読み取りのキャッシュ）
