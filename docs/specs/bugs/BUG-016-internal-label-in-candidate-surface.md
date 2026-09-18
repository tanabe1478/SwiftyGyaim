# BUG-016: 接続辞書の内部ラベルが候補 surface に混入する

- **発見日**: 2026-06-18
- **症状**: `omoku` の候補で `重い形容詞` / `おもい形容詞` が `重く` より上位に表示される。誤って確定すると学習辞書にも登録される。
- **影響**: 品詞説明・接続カテゴリのような内部ラベルが通常の日本語入力候補として露出し、fast-context-rerank の exact 優先でさらに目立ちやすくなる。
- **原因**: 接続辞書の `word` が表示 surface と内部接続ラベルを兼ねている。`omoku = omo + ku = 重 + い形容詞` のように、`ku -> い形容詞` が接続探索で連結され、`WordSearch` 側では connection compound exact も通常の `.exact` として扱われていた。
- **修正**: `ConnectionDict` が `word` を `canStart` / `canTerminate` / `contributesSurface` に正規化して扱うようにし、`い形容詞` / `な形容詞` などの内部ラベル風ノードは探索用に残しつつ surface に寄与させない。さらに `WordSearch` の connection 候補追加直前にも狭い suffix フィルタを置き、インポート済み辞書などへの防御層にする。connection compound exact は通常 `.exact` ではなく `.compound` として扱う。
- **検証**: `ConnectionDictTests` / `WordSearchTests` に `omoku` で `重い形容詞` / `おもい形容詞` が出ず、`重く` が残ること、`keiyoushi -> 形容詞` が残ること、`kyokushoka -> 局所化` が connection compound metadata を持つことを確認するテストを追加。
- **教訓**: 接続辞書では表示 surface と接続制御ノードを同じ `word` に詰め込むと、内部カテゴリが候補に漏れる。`*` だけで全ての内部ノード意味を表現しようとせず、`canStart` / `canTerminate` / `contributesSurface` のように接続用ノードと表示 surface を分離する。
