# BUG-035: 淘汰方式「淘汰なし」が MRU と同じ10,000件切り詰めをしていた

- **日付**: 2026-09-11
- **症状**: 設定画面で「淘汰なし」を選んでも、学習語が10,000件を超えると末尾から消える。enum コメントは `No eviction (unlimited)`。
- **原因**: `WordSearch.evict()` が `.mru, .none` を同じ case で扱い、両方とも `prefix(maxStudyEntries)` で切り詰めていた。ADR-014 が「全モード共通で上限10,000件」と定めたまま、ラベルとコメントだけが「無制限」を名乗っていた。
- **修正**: `.none` では `evict()` を no-op にし、ADR-025 で決定を改めた。設定画面のヒント文も「上限なしで全件保持」に変更。
- **検証**: `WordSearchTests.testEvictNoneKeepsEntriesBeyondCap` / `testEvictMRUTruncatesAtCap`（10,000件を事前生成したファイルを読み込み、追加学習後の件数を確認）。
- **教訓**: 設定の選択肢を追加するときは、各選択肢が実装上も異なる挙動を持つことをテストで示す。同じ case に並べた時点で選択肢の意味が消える。
