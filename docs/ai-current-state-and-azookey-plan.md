# AI変換プロトタイプ現状と azooKey 的候補生成への移行計画

> Status: Draft
> Last updated: 2026-05-22

## 背景

SwiftyGyaim では、まず `ku-nlp/gpt2-small-japanese-char` を使ったローカル GPT-2 reranker を導入し、既存候補の並び替えから AI 活用を開始した。その後、Tab 明示起動の候補強化パイプラインとして、以下を追加した。

- 直前確定テキストを文脈として保持
- Tab 時だけ AI rerank を起動
- ローカル複合候補生成（beam search）
- 語尾補完候補生成
- Google Input Tools 候補の取り込み
- GPT-2 による文脈付き rerank
- raw input を候補 0 に残し、未確定本文をローマ字のまま維持

この結果、`henkankouho` → `変換候補`、`ousyuusuru` → `押収する` のような候補は出せるようになった。一方で、2候補目以降の品質、候補の多様性、接続の自然さ、速度にはまだ課題がある。

## 現在の Tab パイプライン

通常入力時は AI / Google を呼ばない。候補表示中に Tab を押した時だけ以下を実行する。

```text
Tab
  1. 既存候補 snapshot を取得
  2. ローカル複合候補を生成
  3. 語尾補完候補を生成
  4. まずローカル候補だけで GPT-2 rerank
  5. Google Input Tools 候補が返ったら候補集合へ追加
  6. Google込みでもう一度 GPT-2 rerank
  7. raw input を候補0に戻し、候補一覧へ反映
```

狙い:

- 通常入力の軽さを守る
- Tab直後はローカル候補で早く反応する
- Google は遅れて返っても候補強化として使う
- raw input を先頭に残し、Enter誤確定を避ける

## 現在の実装ファイル

| ファイル | 役割 |
| --- | --- |
| `Sources/Gyaim/AIReranker.swift` | AI rerank request/response、Swift in-process heuristic、HTTP/external command client |
| `Sources/Gyaim/AIRerankBackend.swift` | in-process rerank backend 抽象。Zenz/heuristic の切替点 |
| `Sources/Gyaim/InProcessAIReranker.swift` | IMEプロセス内rerank入口。backendを優先順に選ぶ |
| `Sources/Gyaim/ZenzRuntime.swift` | 同梱Zenz/GGUF runtime境界。llama.cpp token inference の接続点 |
| `Sources/Gyaim/LlamaZenzContext.swift` | llama.cpp model/context/vocab を in-process に保持し、token log probability を計算 |
| `Sources/Gyaim/BundledAIRerankModel.swift` | 同梱 GGUF モデルの bundle 解決・memory-map 保持 |
| `Sources/Gyaim/CandidateGenerator.swift` | Tab時のローカル複合候補・補完候補生成 |
| `Sources/Gyaim/GyaimController.swift` | Tab起動、文脈保持、Google後追い、rerank適用 |
| `Sources/Gyaim/WordSearch.swift` | 候補 source に `.google` を追加 |
| `Tools/ai-rerank/gyaim-gpt2-char-rerank-server.py` | resident GPT-2 scoring server |
| `Tools/ai-rerank/evaluate-reranker.py` | ログベース評価 runner |
| `Tools/ai-rerank/extract-gyaim-log-training-data.py` | 確定ログから評価データ抽出 |

## 現在見えている課題

### 1. 2候補目以降の品質が弱い

1位候補は Google / GPT-2 / raw input 制御で改善してきたが、候補リスト全体としてはまだ弱い。

例:

```text
ousyuusuru
```

期待:

```text
押収する
応酬する
押収
おうしゅうする
```

現状ではローカル複合候補が以下のような弱い候補を作ることがある。

```text
追う集する
追う集スる
追う集擦る
```

これは「単語をつなげているだけ」で、品詞・接続・表記自然性を十分に見ていないため。

### 2. Google 依存を減らしたい

Google Input Tools は `houmatsu` → `泡沫`、`ousyuusuru` → `押収する` のような候補生成に強い。一方で、最終的にはローカル完結を目指したい。

Google は当面:

- 候補生成の補助輪
- 辞書改善の teacher
- fallback source

として使う。azooKey 的なローカル候補生成が成熟したら、通常パイプラインから外せる状態を目指す。

### 3. 速度

Tab は明示起動なので通常入力には影響しないが、体感速度はまだ改善余地がある。

主な遅延要因:

- Google API のネットワーク待ち
- 候補数過多による GPT-2 scoring
- torch/MPS inference

対応方針:

- ローカル候補で先に表示、Google は後追い反映
- AI scoring 対象候補数を制限
- 将来的に Core ML / MLX / 軽量LM化を検討

## azooKey から取り込みたいエッセンス

azooKey / AzooKeyKanaKanjiConverter をそのまま移植するのではなく、候補生成思想を取り込む。

### 1. Lattice / graph による候補生成

入力読み全体を、候補語のグラフとして扱う。

```text
henkankouho
  henkan -> 変換 / 返還
  kouho  -> 候補 / こうほ
  henkankouho -> 変換候補
```

これにより、1本の分割だけでなく複数の分割経路を保持できる。

### 2. N-best 経路

目標は1位だけを当てることではなく、妥当な候補集合を複数出すこと。

```text
変換候補
返還候補
変換こうほ
へんかん候補
変換候補です
```

のような候補リストを作る。

### 3. コスト設計

候補順位を以下の合成で決める。

- word cost
- connection cost
- exact / prefix cost
- source bias
- user frequency
- recency
- context language model score
- 表記自然性 penalty

### 4. 接続制約

単純連結ではなく、接続の自然さを見る。

例:

- 名詞 + 名詞
- 名詞 + する
- 動詞連用形 + 助動詞
- 形容詞 + です

不自然な候補は下げる/落とす。

例:

```text
追う集する
追う集スる
追う集擦る
```

### 5. 候補多様性

似た候補や表記ゆれが上位を占有しないようにする。

悪い例:

```text
追う集する
追う集スる
追う集擦る
追うしゅうする
```

候補リストとしては、意味・表記・文節分割が違うものを残したい。

## 次に実装する方針

### Phase A: CandidateGenerator を分離（実装済み）

`GyaimController` から Tab候補生成ロジックを以下へ切り出した。

```text
Sources/Gyaim/CandidateGenerator.swift
```

責務:

```swift
generate(
  inputPat: String,
  context: String,
  baseCandidates: [SearchCandidate],
  wordSearch: WordSearch
) -> [SearchCandidate]
```

### Phase B: CandidateKind を導入（実装済み）

`CandidateSource` だけでは候補の性質を表しきれないため、`SearchCandidate.kind` を追加した。AI request には `kind` も含める。

```swift
enum CandidateKind {
    case raw
    case exact
    case prefix
    case compound
    case completion
    case google
    case kana
}
```

これにより、source と kind を分けて順位制御する。

### Phase C: Lattice / beam search を強化（着手）

現状の簡易 beam search に、segment cost / source bias / 不自然表記 penalty を追加した。特に「ひらがな終端 + 漢字開始」「カタカナ + ひらがな」のような不自然な script transition と、1文字漢字segmentを下げる。今後さらに以下へ発展させる。

- 任意分割
- N-best path
- segment候補上限
- beam width
- exact優先
- prefix completionの別扱い
- 不自然表記 penalty
- duplicate / near-duplicate 除去

### Phase D: scoring を構造化（着手）

`InProcessAIReranker` を追加し、Tab直後の候補順補正は Swift プロセス内の単一入口に集約した。さらに `AIRerankBackend` と `ZenzRuntime` を追加し、`BundledZenzAIRerankBackend`（同梱モデル prepare + runtime scoring）→ `HeuristicAIRerankBackend`（常時fallback）の優先順で選ぶ構造にした。また `zenz-v3.1-xsmall-gguf` を app bundle に同梱し、`BundledAIRerankModel` で memory-map してIMEプロセス内に保持する。`llama` binary framework を Swift Package として接続し、`LlamaZenzContext` で `llama_backend_init` / `llama_model_load_from_file(use_mmap: true)` / `llama_init_from_model` / `llama_model_get_vocab` / `llama_decode` / logits 取得まで実行する。`BundledZenzRuntime.rerank(_:)` は `読み: <hiragana>\n変換:` prompt に続く candidate text の平均 log probability を Swift heuristic score に小さく加算して order を返す。まだ Zenzai本来の candidate evaluation prompt ではないため、次は azooKey の prompt/constraint に寄せる。GPT-2 server / 単発reranker は `CandidateKind` を受け取り、暫定的な kind bias を score に加える。

最終 score 例:

```text
finalScore =
  sourceBias
  + kindBias
  + userFrequency
  + recency
  + connectionScore
  + lmScore * weight
  - unnaturalPenalty
  - duplicatePenalty
```

### Phase E: Google を fallback / teacher 化

Google候補が選ばれたら local/study に取り込む。十分なローカル候補がある場合は Google を呼ばない、または Tab 2回目だけにする。

## 当面の成功条件

- `hokankouho` で `補完候補` が出る
- `henkankouho` で `変換候補` が上位に出る
- `ousyuusuru` で `押収する` が上位に出る
- `konkaihakanaritaihenndesita` で `今回はかなり大変でした` が候補に出る
- raw input は候補0に残り、誤確定しない
- Tab通常時の初回反応が軽い
- 2候補目以降に不自然な混在候補が並びにくい

## 参考

- https://knowledge.sakura.ad.jp/42901/
- https://github.com/azooKey/azooKey
- https://github.com/azooKey/AzooKeyKanaKanjiConverter
