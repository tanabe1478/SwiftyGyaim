# ADR-022: 辞書制約付き生成（有界列挙 + Zenz選択方式）

## Status

Accepted

## Decision

Tab経路の `kind=zenz` 候補を、自由生成から**辞書制約付き選択**に置き換える。

1. `ConnectionDict.constrainedCompositions(pat:maxResults:maxDepth:)` が、接続辞書の状態遷移に従う**完全変換の表層集合**を有界に列挙する（既定: 最大12件・深さ8。結果上限と深さ上限で再帰を打ち切る）
2. `ZenzRuntime.selectCandidates` が各表層を条件付き平均log probability（`LlamaZenzContext.score`、キャッシュ有効）でスコアし、上位（既定3件、`aiRerankZenzGenerationLimit` で最大6）を `kind=zenz` / `source=connection` 候補として返す
3. 既存候補集合に含まれる表層はスコア対象から除外する（通常列挙で上位に出ている合成を再評価しない。モデルの仕事は「列挙順で沈んだ合成の救済」）
4. 従来の自由生成（greedy 12 token）は `aiRerankUseZenzFreeGeneration=true` の明示opt-inに降格する

モデルは列挙集合の**中から選ぶことしかできない**ため、辞書が組み立てられない語（幻覚）は構造上出力されない。

## Context

従来の `kind=zenz` 候補はZenzの自由生成で、文字種フィルタを通しても辞書に存在しない語を生成しうるため、安全のため1候補・短文に制限されていた。モデルの能力を「辞書のカバレッジ内での最適選択」に限定できれば、この制限を緩和しつつ「辞書が主、AIが従」（roadmap #62）を構造的に保証できる。

接続辞書は Gyaim/Gictionary 由来の状態遷移辞書であり、`generateCand()` は完全変換の合成を既に列挙できる。ただし無制限再帰（深さ・件数の打ち切りなし）で、長い読みや曖昧な接続では分岐が爆発しうる（issue #29 の懸念）。

## Consideration

1. **logitsマスキング方式（真の制約付きdecoding）**: 生成の各ステップで「現在の辞書遷移状態から許される次トークン」以外のlogitsをマスクする。列挙爆発に強く、理論的に最も正しい。しかし (a) トークン境界と形態素境界の整合（トークンtrie構築）が複雑、(b) llama依存のためユニットテストできない、(c) 並列辞書状態の管理が必要。**将来の拡張として保留**し、本ADRの方式で列挙上限がボトルネックになった時に再検討する。
2. **有界列挙 + スコアリング方式（採用）**: 「制約付き生成」を「制約集合の列挙 + LMによる選択」として実現する。列挙は純粋関数でテスト可能、スコアは実装済みの `score()`（FIFOキャッシュ付き）を再利用。読み〜12文字程度のIME入力では列挙上限12件で実用十分。
3. **通常のrerankで賄う（何もしない）**: 通常候補のZenz scoringは上位8件のみで、列挙順で沈んだ合成には届かない。却下。

## Consequences

- 良い点: `kind=zenz` 候補が常に辞書由来になり、確定してもstudy/local経由で辞書エコシステムに整合する。生成候補数を1→3に緩和できた
- 良い点: 制約集合の列挙（ConnectionDict）とモデル選択（ZenzRuntime）が分離され、それぞれ独立にテスト・改善できる。列挙APIは今後の辞書デバッグ・辞書提案workflow（#59 方向性4）でも再利用可能
- 悪い点: 列挙上限12件を超える曖昧な読みでは、上限外の合成をモデルが選べない（truncatedログで観測可能にした）。logitsマスキング方式への移行条件はこのログで判断する
- 悪い点: Tab経路のレイテンシに表層数×score() が加わる（キャッシュ・上限で有界。Tabは明示操作のため許容）
- user-dict語を含む合成（例: ローカル登録語+接続語尾）は接続グラフ外のため本方式では列挙されない。CandidateGenerator の lattice（文脈対応済み）が引き続き担う

## References

- issue #59 / roadmap #62
- docs/adr/021-exact-homophone-direct-logprob.md（直接logprob比較の先行事例）
- docs/ai-roadmap.md（辞書が主、AIが従）
