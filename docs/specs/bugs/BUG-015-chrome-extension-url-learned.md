# BUG-015: chrome-extension URL が選択テキスト候補として混入し誤学習される

- **発見日**: 2026-06-17
- **症状**: `taisyou` などの入力で `chrome-extension://.../app.html` が候補ウィンドウ先頭付近に表示され、誤って確定すると study 辞書へ学習される。ログには `Captured selected text: "chrome-extension://..."` と `Studied: "chrome-extension://..."` が残る。
- **影響**: Chrome拡張ページのURLが日本語変換候補に混入し、削除しても再び選択テキスト候補として出ると再学習される。
- **原因**: `isValidExternalCandidate()` が URL 除外を `hasPrefix("http")` だけで判定しており、`chrome-extension://` や `obsidian://` など URL scheme 形式の文字列を外部候補として許可していた。
- **修正**: 外部候補検証で前後改行もtrimし、lowercase化した文字列が `://` を含む場合は無効とする。従来の `http` prefix と Gyazo hash 除外は維持。
- **検証**: `ExternalCandidateTests` に `chrome-extension://...` / `obsidian://...` の無効化と、選択テキスト候補への混入防止テストを追加。
- **教訓**: 外部候補は選択中テキスト・クリップボード由来で、アプリ内部URLやdeep linkも入りうる。URL判定は `http(s)` だけに限定せず、scheme形式全般を候補から除外する。
