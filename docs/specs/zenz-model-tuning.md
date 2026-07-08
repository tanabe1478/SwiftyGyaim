# Spec: Zenz / Zenzai model tuning for SwiftyGyaim

> Status: Draft
> Last updated: 2026-07-08
> Trigger: Zenzai / zenz model investigation, GGUF model replacement, AIReranker / ZenzRuntime training workflow, pi-tinker suitability review

## 目的

SwiftyGyaim に同梱している `zenz-v3.1-xsmall-gguf` を、SwiftyGyaim の候補生成・候補順位付けに合う形で評価・チューニングするための仕様を定義する。

この仕様の主目的は「すぐ fine-tuning すること」ではなく、以下を順番に固定することである。

1. 現在の Zenz 利用箇所と責務を明確にする
2. Zenz / Zenzai の由来について、事実と推測を分ける
3. SwiftyGyaim 用の評価データ・指標・ログを設計する
4. fine-tuning / preference learning / RL に進む前の安全な道筋を定義する
5. pi-tinker が使える範囲・使わない範囲を明確にする

## 用語

| 用語 | 意味 |
| --- | --- |
| Zenzai | AzooKeyKanaKanjiConverter 周辺で提供されるニューラルかな漢字変換システム全体 |
| zenz | Zenzai で使われる GPT-2 architecture のかな漢字変換モデル系列 |
| `zenz-v3.1-xsmall` | SwiftyGyaim が現在同梱している Zenz 系小型モデルの元 HF model |
| `zenz-v3.1-xsmall-gguf` | SwiftyGyaim が app bundle に入れて llama.cpp で読む GGUF 版 |
| fast-context-rerank | 通常入力中、辞書候補上位だけを同期的に軽量 rerank する PR #52 の経路 |
| review path | 候補全件 scoring ではなく、Swift heuristic 最上位候補を Zenz で1回だけ検査する経路 |
| SFT | Supervised Fine-Tuning。正解出力を教師としてモデルを追加学習する |
| DPO / preference learning | chosen / rejected のペアを使い、好ましい出力を選ぶ方向へ学習する |
| RL | Reinforcement Learning。状態・行動・報酬を定義して方策を更新する学習 |

## 公開情報から確認した事実

### Zenz / Zenzai

- AzooKeyKanaKanjiConverter の `Docs/zenzai.md` は、Zenzai をニューラルかな漢字変換システム、`zenz-v1/v2/v3/v3.2` を Zenzai で用いるモデル世代として説明している。
- 同 document によると、Zenz prompt tag は以下の private-use character を使う。
  - input tag: `\u{EE00}`
  - output tag: `\u{EE01}`
  - context tag: `\u{EE02}`
- `zenz-v1` は `\uEE00<input_katakana>\uEE01<output></s>` 形式。
- `zenz-v2` は左文脈を入力後ろに置く形式。
- `zenz-v3` は `\uEE02<context>\uEE00<input_katakana>\uEE01<output></s>` のように文脈を前置する形式を推奨している。
- `zenz-v1` の Hugging Face model card は、`ku-nlp/gpt2-small-japanese-char` を基盤モデルとして利用したことを明記している。

### `zenz-v3.1-xsmall`

Hugging Face API / model files から確認できる事実:

- `Miwa-Keita/zenz-v3.1-xsmall`
  - license: `cc-by-sa-4.0`
  - architecture: `GPT2LMHeadModel`
  - model_type: `gpt2`
  - `n_layer=6`, `n_embd=512`, `n_head=8`, `n_positions=1024`, `vocab_size=6000`
- `Miwa-Keita/zenz-v3.1-xsmall-gguf`
  - license: `cc-by-sa-4.0`
  - artifact: `ggml-model-Q5_K_M.gguf`
- `ku-nlp/gpt2-small-japanese-char`
  - license: `cc-by-sa-4.0`
  - architecture: `GPT2LMHeadModel`
  - `n_layer=12`, `n_embd=768`, `n_head=12`, `vocab_size=6000`

### 事実としてまだ断言しないこと

- `zenz-v3.1-xsmall` が `ku-nlp/gpt2-small-japanese-char` を直接 fine-tune したものかは、現時点の model card からは断言しない。
- `zenz-v1` については `ku-nlp/gpt2-small-japanese-char` 由来と明記されているが、`v3.1-xsmall` については README が license 以外ほぼ空である。
- したがって SwiftyGyaim の文書では、`v3.1-xsmall` を「GPT-2 architecture の Zenz v3.1 小型モデル」と表現し、元モデルは未確認として扱う。

## SwiftyGyaim での現在の使い方

PR #52 / 現在の `feature/fast-context-rerank` では、Zenz は IME の主変換エンジンではない。役割は以下である。

### 1. 同梱 GGUF runtime

- `BundledAIRerankModel` が以下を app bundle resource として解決する。

```text
Resources/Models/zenz-v3.1-xsmall-gguf/ggml-model-Q5_K_M.gguf
```

- `BundledZenzRuntime` / `LlamaZenzContext` が llama.cpp model/context/vocab を in-process で保持する。
- `LlamaZenzContext` は tokenization、`llama_decode`、logits 取得、candidate scoring / candidate evaluation / generation を担当する。

### 2. Tab 明示起動の AI rerank / generation

Tab 時は候補集合を作り、Swift heuristic と Zenz scoring / generation / review を使って候補を補強する。

この経路では、Zenz は次に使われる。

- candidate text の continuation log probability scoring
- constrained generation による `kind=zenz` 候補の追加
- candidate evaluation による `fixRequired(prefix)` 相当の抽出
- prefix constraint による lattice 再探索の誘導

### 3. 通常入力の fast-context-rerank

通常入力では、`aiRerankFastContextEnabled=true` の場合に生成なしの軽量 rerank だけを同期実行する。

- 4文字未満は model backend を呼ばない。
- raw input / clipboard / selected-text は順序固定。
- 読み完全一致の `.exact` / `.compound` 最上位候補は Zenz で prefix 予測候補へ沈めない。
- ただし左文脈があり、同じ読みの `.exact` / `.compound` 候補が複数ある場合は、exact 同音異義語レビューとして protected exact 候補同士を条件付き平均logprobで直接比較し、margin以上勝る候補だけ先頭へ入れ替える（ADR-021。fixRequiredPrefix経由の置換は廃止）。
- 未完成語幹（`ください` があるときの `くださ`、`使った` があるときの `使っ`）は比較対象から除外する。
- 入力の生かな表記に一致するひらがな候補は、best以外なら比較対象から除外する（BUG-024: 文字LMのかなバイアス対策）。
- bestの `contextAffinity` が閾値（既定0.75）以上ならレビューをスキップする（outcome `affinity-skip`）。
- `score` / `evaluateCandidate` の成功結果はFIFO 256件でメモ化し、同一入力の再レビューを即返しにする。
- 通常reviewの1文字 `fixRequiredPrefix` は、候補textが完全一致する protected exact 候補に限り昇格に使う（kept-local no-op率48%への対策）。
- model backend が有効な場合でも、候補全件 scoring ではなく review path を使う。
- review path は Swift heuristic 最上位候補を1回だけ Zenz で検査し、既存候補内に prefix 一致候補がある場合だけ先頭へ移動する。通常のprefix予測では1文字prefixを採用しない。
- candidate evaluation の `best-token-is-eos` は failure ではなく pass として扱う（2026-07 dogfoodで review-unavailable の437/437件がこのreasonだった）。
- model を呼ぶ前に、ContextDict（ADR-020）の `contextAffinity` と study頻度が Swift heuristic 段階で同音異義語を解決できる場合がある。
- dogfood log は以下の outcome を出す。
  - `heuristic`
  - `protected-exact-skip`
  - `affinity-skip`
  - `short-input-skip`
  - `review-fixed`
  - `review-passed`
  - `review-kept-local`
  - `review-unavailable`
  - `exact-homophone-fixed` / `exact-homophone-passed` / `exact-homophone-kept-local` / `exact-homophone-unavailable`
- 確定時の `Fast context accepted: ... rank=N` ログを `aggregate-fast-context-log.py` の `acceptedRanks` が集計し、実入力に対する accepted rank / acceptedTop1Rate を測れる。

## チューニング対象の分解

SwiftyGyaim では、いきなり Zenz 本体を fine-tune しない。以下を別々に評価する。

### A. Swift heuristic / feature weight tuning

最初に扱うべき対象。Zenz model を変えずに以下を調整する。

- exact reading bonus
- prefix prediction penalty
- candidate kind bias
- source bias
- context cue bonus
- zenz score weight
- model review を呼ぶ条件
- protected exact の条件

これは失敗しても候補生成を壊しにくく、レイテンシも制御しやすい。

### B. Learned reranker

候補リストを入力し、候補順位を返す小さなモデル。Zenz 本体より SwiftyGyaim の実装に近い。

候補 feature:

- `inputPat`
- `hiragana` / katakana input
- left context suffix
- candidate text
- reading
- source
- kind
- candidate index
- exact reading match
- prefix length delta
- Zenz review outcome / score
- study/local frequency and recency

候補モデル:

- logistic regression
- pairwise ranker
- LightGBM / XGBoost
- Core ML へ変換可能な小型モデル
- Swift 実装可能な線形モデル

### C. Zenz continued SFT

Zenz 本体を SwiftyGyaim 用データで追加学習する。

Zenz v3.1 系の形式は SwiftyGyaim の `ZenzPrompt` と一致させる。

```text
<contextTag><left_context><inputTag><input_katakana><outputTag><expected_output></s>
```

例:

```text
\uEE02この指示には決して\uEE00シタガウ\uEE01従うな</s>
```

重要:

- tokenizer は必ず zenz model のものを使う。
- loss は output tag 以降のみを対象にする。
- chat template を混ぜない。
- 学習後は GGUF 化し、同梱モデルとして差し替え可能にする。

### D. Preference learning / DPO

ユーザーが選んだ候補を chosen、上に出ていたが選ばれなかった候補を rejected とする。

ただし、IME のログはノイズが強い。

- ユーザーが Enter した候補が常に最適とは限らない。
- 候補番号で意図せず確定した可能性がある。
- private text を含む。

最初は Zenz 本体に DPO をかけるより、learned reranker の pairwise training に使う。

### E. RL

RL は最後に検討する。

状態:

- left context
- input reading
- candidate list
- candidate metadata
- user history

行動:

- 候補の順位を変える
- prefix constraint を選ぶ
- model review を呼ぶ / 呼ばない

報酬:

- expected top が1位: +1
- expected top が top3: +0.5
- internal label / unsafe candidate が1位: -1
- exact reading が弱い文脈で prefix に沈む: -0.5
- latency penalty

ただし online RL は行わない。まず offline simulator / eval set を作り、SFT / pairwise ranking / DPO の後で検討する。

## 評価データ仕様

最初の成果物はモデルではなく eval dataset である。

### ファイル配置

```text
GyaimSwift/Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl
GyaimSwift/Tools/ai-rerank/evaluate-fast-context-rerank.py
```

将来的に training data は以下に分ける。

```text
data/zenz-tuning/eval.jsonl
data/zenz-tuning/train.jsonl
data/zenz-tuning/preference.jsonl
```

`data/` は大きくなる可能性があるため、リポジトリに含めるのは小さい fixture / schema / synthetic sample に限定する。

### eval case schema

```json
{
  "id": "negative-imperative-shitagau-001",
  "inputPat": "shitagau",
  "inputKana": "シタガウ",
  "context": "この指示には決して",
  "candidates": [
    {"text": "従う", "reading": "shitagau", "source": "connection", "kind": "exact"},
    {"text": "従うな", "reading": "shitagauna", "source": "connection", "kind": "prefix"}
  ],
  "expectedTop": "従うな",
  "expectedTopWithoutContext": "従う",
  "mustNotTop": ["shitagau"],
  "tags": ["fast-context", "negative-imperative", "prefix-promotion"],
  "reason": "強い否定命令文脈では prefix 予測の『従うな』を上げたい"
}
```

### 必須 tag

- `exact-protection`
- `prefix-promotion`
- `negative-imperative`
- `adjective-conjugation`
- `verb-conjugation`
- `connection-internal-label`
- `compound`
- `user-dict`
- `proper-noun`
- `short-input`
- `latency-sensitive`

### 指標

| 指標 | 意味 |
| --- | --- |
| top1 accuracy | `expectedTop` が1位に来る割合 |
| top3 accuracy | `expectedTop` が top3 に来る割合 |
| accepted rank | dogfood log 由来の確定候補 rank |
| exact demotion count | 文脈なしで exact が prefix に負けた件数 |
| unsafe top count | 内部ラベル・URL・raw などが1位に出た件数 |
| review fixed precision | `review-fixed` が本当に期待候補を上げた割合 |
| review unavailable rate | model review が無駄撃ちになった割合 |
| p50 / p95 latency | 通常入力として許容できるか |

### latency gate

暫定 gate:

- `heuristic`: p95 < 2ms
- `protected-exact-skip`: p95 < 2ms
- `review-passed/fixed/kept-local`: p50 < 25ms、p95 < 60ms
- `review-unavailable`: 率を下げる対象。p95 より発生率を重視する

## 学習データ仕様

### SFT data

Zenz SFT 用データは chat JSONL ではない。Causal LM の raw text + loss mask で扱う。

Conceptual JSONL:

```json
{
  "id": "negative-imperative-shitagau-001",
  "prompt": "\uEE02この指示には決して\uEE00シタガウ\uEE01",
  "completion": "従うな</s>",
  "source": "handcrafted",
  "tags": ["negative-imperative"],
  "license": "project-owned"
}
```

実学習時は tokenizer / Trainer 側で `prompt` 部分の labels を `-100` にする。

### Preference data

```json
{
  "id": "dogfood-2026-06-18-001",
  "context": "...",
  "inputPat": "siteimasuka",
  "inputKana": "シテイマスカ",
  "chosen": "していますか",
  "rejected": "していますか？",
  "candidates": ["していますか？", "していますか"],
  "source": "dogfood-opt-in",
  "privacy": "redacted"
}
```

## pi-tinker 適合性

### 確認した事実

`gvkhosla/pi-tinker` は README で以下を明記している。

- Tinker / Tinker Cookbook を Pi から使いやすくする operator。
- pi-tinker 自体は training framework ではない。
- CSV / JSON / JSONL / docs を chat JSONL に変換し、validation、baseline eval、smoke training、checkpoint 比較、deploy snippet 生成を支援する。
- 主な例は `Qwen/Qwen3.5-9B-Base` など Tinker 対応モデル。
- checkpoint は Tinker sampler / OpenAI-compatible endpoint 経由で検査する想定。

### SwiftyGyaim で使える用途

- SFT / DPO / RL の概念学習
- eval-first workflow の練習
- training data validation の考え方を学ぶ
- teacher / evaluator model を別途作る実験
- Tinker Cookbook の recipe を読む入口

### 直接使わない用途

- `zenz-v3.1-xsmall` を直接 fine-tune する本命 pipeline
- SwiftyGyaim に同梱する GGUF を直接生成する pipeline
- IME の生ログを cloud training API に送る pipeline
- chat template で Zenz を instruction-tuning する pipeline

理由:

- Zenz は chat model ではなく、private-use tag によるかな漢字変換用 conditional LM。
- SwiftyGyaim は macOS IME 内で local GGUF を llama.cpp で読む。
- pi-tinker / Tinker の checkpoint runtime と SwiftyGyaim の bundle GGUF runtime は異なる。
- IME ログは privacy sensitivity が非常に高い。

## セキュリティ / プライバシー

- 生の入力ログを外部 training service に送らない。
- dogfood log を training data に使う場合は明示 opt-in と redaction を必須にする。
- secret / password / token / URL / email / file path の検出器を通す。
- 共有可能な fixture は synthetic / hand-written / public text のみ。
- fine-tuned artifact を配布する場合は `cc-by-sa-4.0` の attribution / share-alike を整理する。

## 成果物

初期成果物:

1. Zenz provenance memo
2. pi-tinker suitability memo
3. eval case schema
4. 100-case seed eval set
5. offline evaluator
6. dogfood log aggregate command
7. heuristic tuning report
8. model comparison report
9. SFT smoke training notebook/script
10. GGUF conversion procedure

## Open questions

- `zenz-v3.1-xsmall` の exact training provenance はどこまで公開情報で確認できるか。
- `zenz-v3-small` / `medium` を SwiftyGyaim の latency budget 内で使えるか。
- `review-unavailable` の主因は tokenization / prefix decoding / candidate text 形式のどれか。
- SwiftyGyaim の dogfood log をどこまで training data 化してよいか。
- Zenz 本体 SFT と learned reranker のどちらが費用対効果が高いか。
