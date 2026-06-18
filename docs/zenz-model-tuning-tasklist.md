# Zenz / Zenzai model tuning tasklist

> Status: Draft
> Last updated: 2026-06-18
> Parent spec: `docs/specs/zenz-model-tuning.md`
> Related PR: <https://github.com/tanabe1478/SwiftyGyaim/pull/52>

## 方針

- OFF に逃げず、model backend ON の dogfood を続けながら改善する。
- ただし、いきなり Zenz 本体を fine-tune しない。
- 先に評価データ・評価指標・ログ集計・現行 heuristic の上限を固める。
- 事実・推測・実験結果を分けて記録する。
- IME 入力ログは private data として扱い、外部 training service に生ログを送らない。

## Milestone 0: 現状と由来の固定

### M0-1. 現在の SwiftyGyaim Zenz 利用経路を棚卸しする

- [ ] `BundledAIRerankModel.swift` の model resource path を記録する
- [ ] `ZenzPrompt.swift` の tag 定義を記録する
- [ ] `ZenzRuntime.swift` の用途を分ける
  - [ ] full rerank scoring
  - [ ] fast-context review path
  - [ ] generation
  - [ ] alternative candidate / review loop
- [ ] `GyaimController.swift` の fast-context gating を記録する
  - [ ] min input length
  - [ ] max context length
  - [ ] candidate limit
  - [ ] protected exact skip
- [ ] `docs/specs/ai-rerank.md` と `docs/specs/input-flow.md` の記述との差分を確認する

Definition of done:

- [ ] `docs/specs/zenz-model-tuning.md` の「SwiftyGyaim での現在の使い方」がコードと一致している

### M0-2. Zenz / Zenzai の公開情報を一次情報で確認する

- [ ] AzooKeyKanaKanjiConverter `Docs/zenzai.md` を確認する
- [ ] AzooKeyKanaKanjiConverter の `ZenzPromptBuilder.swift` を確認する
- [ ] `Miwa-Keita/zenz-v3.1-xsmall` の HF model files を確認する
  - [ ] license
  - [ ] config
  - [ ] tokenizer files
  - [ ] README の有無と内容
- [ ] `Miwa-Keita/zenz-v3.1-xsmall-gguf` の HF artifact を確認する
- [ ] `Miwa-Keita/zenz-v1` の model card を確認する
- [ ] `ku-nlp/gpt2-small-japanese-char` の model card / license / config を確認する
- [ ] 「確認できた事実」と「推測」を分けて doc に追記する

Definition of done:

- [ ] `zenz-v1` と `zenz-v3.1-xsmall` の由来を混同しない記述になっている
- [ ] `zenz-v3.1-xsmall` の元モデルを断言しない理由が書かれている

### M0-3. pi-tinker の適合性を確認する

- [ ] `gvkhosla/pi-tinker` を clone / read する
- [ ] README の位置づけを確認する
  - [ ] training framework ではない
  - [ ] Tinker / Tinker Cookbook operator
  - [ ] chat JSONL / SFT workflow 中心
- [ ] Tinker 対応 model family を確認する
- [ ] SwiftyGyaim の local GGUF runtime との差分を整理する
- [ ] 使える用途 / 使わない用途を doc に追記する

Definition of done:

- [ ] pi-tinker を「直接 GGUF を作る本命手段」として扱わないことが明文化されている
- [ ] 学習ロードマップ上の補助用途が明文化されている

## Milestone 1: 評価データ基盤

### M1-1. eval case schema を実装する

- [x] `GyaimSwift/Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl` を作る
- [x] schema fields を固定する
  - [x] `id`
  - [x] `inputPat`
  - [x] `inputKana`
  - [x] `context`
  - [x] `candidates[]`
  - [x] `expectedTop`
  - [x] `mustNotTop[]`
  - [x] `tags[]`
  - [x] `reason`
- [x] fixture loader test を追加する
- [x] malformed case を検出する validation を追加する

実装:

- `GyaimSwift/Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl`
- `GyaimSwift/Tools/ai-rerank/validate-fast-context-eval-cases.py`

Definition of done:

- [x] JSONL fixture が validation script で parse される
- [x] schema mismatch が CI test failure になる

### M1-2. seed eval set 100件を作る

進捗: 30/100件。

カテゴリ別目標:

- [ ] exact protection: 20件（現在19件）
- [ ] prefix promotion: 15件（現在5件）
- [ ] negative imperative: 10件（現在5件）
- [ ] adjective conjugation: 10件（現在5件）
- [x] verb conjugation: 10件（現在11件）
- [ ] connection internal label regression: 10件（現在6件）
- [ ] compound candidate: 10件（現在9件）
- [ ] proper noun / user dict: 10件（現在5件: proper noun 3件 + user-dict 2件）
- [ ] short input / latency sensitive: 5件（現在4件）

初期候補例:

- [ ] `shitagau`: `従う` vs `従うな`
- [ ] `kiru`: `切る` vs `切るな`
- [ ] `omoku`: `重く` / `重い形容詞` regression
- [ ] `keiyoushi`: `形容詞` standalone should remain
- [ ] `kyokushoka`: compound candidate kind
- [ ] `sitehosii`: `してほしい`
- [ ] `siteimasuka`: `していますか`
- [ ] `kinou`: `機能` vs `昨日`
- [ ] `rogu`: `ログ`

Definition of done:

- [ ] seed 100件で現行 heuristic / model path の baseline が取れる

### M1-3. offline evaluator を作る

- [x] `GyaimSwift/Tools/ai-rerank/evaluate-fast-context-rerank.py` を作る
- [x] Swift test fixture と同じ schema を読む
- [x] 以下を出力する
  - [x] top1 accuracy
  - [x] top3 accuracy
  - [x] unsafe top count
  - [x] exact demotion count
  - [x] latency summary
  - [x] outcome summary
- [x] CI では lightweight mode のみ実行する
- [x] heavy Zenz mode は env opt-in にする
  - `RUN_ZENZ=1` または `--backend command` と `GYAIM_FAST_CONTEXT_EVAL_COMMAND` で、AIRerankRequest JSON を受け取る外部 backend に委譲できる

実装:

- `GyaimSwift/Tools/ai-rerank/evaluate-fast-context-rerank.py`
- default は Swift `AIReranker.localRerank` の軽量 Python port
- 現在の seed 30件 baseline: top1 `30/30`, top3 `30/30`, unsafe top `0`, exact demotion `0`

Definition of done:

- [x] `RUN_ZENZ=0` で速い評価が通る
- [ ] `RUN_ZENZ=1` で local GGUF を使った評価ができる

## Milestone 2: dogfood log から改善する

### M2-1. dogfood log aggregator を作る

- [x] `~/.gyaim/gyaim.log` から fast-context 行を抽出する script を作る
- [x] outcome 別に集計する
  - [x] `heuristic`
  - [x] `protected-exact-skip`
  - [x] `review-fixed`
  - [x] `review-passed`
  - [x] `review-kept-local`
  - [x] `review-unavailable`
- [x] `topChanged=true/false` を集計する
- [x] input length 別 latency を集計する
- [x] candidate count 別 latency を集計する

実装: `GyaimSwift/Tools/ai-rerank/aggregate-fast-context-log.py`

Definition of done:

- [x] 1コマンドで直近30分 / 24時間の p50 / p95 / max が出る

### M2-2. review-unavailable の原因調査

- [x] `evaluateCandidate` が nil を返す理由を分解する
  - [x] prompt token empty
  - [x] candidate token empty
  - [x] logits failure
  - [x] best token decode failure
  - [x] prefix decode mismatch
- [x] log に reason を出す
- [x] reason 別に発生率を集計する

実装:

- `LlamaZenzContext.evaluateCandidate(... failureReason:)`
- `ZenzRuntime.fastContextReviewRerank` の `reason=<detailed-reason>` ログ
- `aggregate-fast-context-log.py` の `reviewEvents.unavailable:<reason>` 集計

Definition of done:

- [x] `review-unavailable` が `reason=evaluate-candidate-nil` だけでなく詳細 reason で分類される

### M2-3. review-fixed の品質確認

- [ ] `review-fixed topChanged=true` のケースを抽出する
- [ ] 良化 / 悪化 / 不明に手動ラベルする
- [ ] 悪化パターンを tag 化する
- [ ] `prefix` が短すぎる場合の制約を検討する

Definition of done:

- [ ] `review-fixed precision` を計測できる

## Milestone 3: heuristic / rule tuning

### M3-1. feature weight を明示化する

- [ ] `AIReranker.localScore` の feature breakdown を debug 可能にする
- [x] eval runner で候補ごとの feature contribution を出す
  - `evaluate-fast-context-rerank.py --show-features`
  - `negative-imperative-kiru-001` は `絶対に` を negative imperative cue に追加して改善済み
  - `polite-question-siteimasuka-001` は文末 `？` penalty 追加で改善済み
- [ ] feature weight を設定化するか、tuning script から sweep 可能にする

対象 feature:

- [ ] source bias
- [ ] kind bias
- [ ] exact reading bonus
- [ ] prefix prediction penalty
- [ ] context prediction bonus
- [ ] kanji bonus
- [ ] natural phrase bonus
- [ ] script transition penalty
- [ ] zenz score weight

Definition of done:

- [ ] どの feature のせいで候補が上がったか説明できる

### M3-2. grid search / random search

- [ ] seed eval set に対して weight sweep を行う
- [ ] top1 / top3 / unsafe / latency を比較する
- [ ] 現行値との差分 report を作る
- [ ] 勝った weight を固定テストに落とす

Definition of done:

- [ ] model fine-tuning なしで改善できる上限が見える

## Milestone 4: model comparison

### M4-1. 現行 GGUF と HF non-quantized の差を比較する

- [ ] `Miwa-Keita/zenz-v3.1-xsmall` を Transformers で読む script を作る
- [ ] 同じ eval cases で score / review を再現する
- [ ] GGUF Q5_K_M と順位差を比較する

Definition of done:

- [ ] 量子化が順位に与える影響が見える

### M4-2. small / medium 系の比較

- [ ] `zenz-v3-small-gguf` を別 resource path で試す
- [ ] memory footprint を測る
- [ ] p50 / p95 latency を測る
- [ ] top1 / top3 improvement を測る

Definition of done:

- [ ] xsmall を鍛えるべきか、small を使うべきかの判断材料がある

## Milestone 5: Zenz SFT smoke

### M5-1. SFT dataset builder

- [ ] eval cases から SFT examples を生成する
- [ ] `ZenzPrompt` と同じ tag を使う
- [ ] prompt 部分を loss mask する collator を作る
- [ ] small synthetic train / validation split を作る

Definition of done:

- [ ] 10件の synthetic data で overfit smoke test ができる

### M5-2. PEFT / LoRA training script

- [ ] `Tools/zenz-tuning/train_lora.py` を作る
- [ ] base model: `Miwa-Keita/zenz-v3.1-xsmall`
- [ ] tokenizer を base と同一に固定する
- [ ] LoRA rank / lr / epochs を config 化する
- [ ] validation loss と exact-match generation を出す

Definition of done:

- [ ] 10件 overfit で expected output を greedy decode できる

### M5-3. GGUF conversion path

- [ ] LoRA merge 手順を確認する
- [ ] HF merged model を保存する
- [ ] llama.cpp converter で GGUF 化する
- [ ] Q5_K_M quantize する
- [ ] SwiftyGyaim app bundle に差し替える
- [ ] `run-fast-context-rerank-emulation.sh` で smoke test する

Definition of done:

- [ ] fine-tuned smoke model を SwiftyGyaim が読み込める

## Milestone 6: preference learning / RL の準備

### M6-1. preference data extraction

- [ ] dogfood log から chosen / rejected pair を作る条件を定義する
- [ ] 誤確定・番号選択・deactivation 確定を区別する
- [ ] private data redaction を入れる
- [ ] opt-in export command を作る

Definition of done:

- [ ] 人間が確認可能な preference JSONL が作れる

### M6-2. pairwise reranker

- [ ] Zenz 本体ではなく小型 reranker に preference data を使う
- [ ] pairwise loss を試す
- [ ] Swift / Core ML へ入れられる形式を検討する

Definition of done:

- [ ] Zenz SFT と learned reranker の費用対効果を比較できる

### M6-3. RL は設計だけに留める

- [ ] offline reward 関数を設計する
- [ ] simulator を eval runner 上に作る
- [ ] online RL は明示的に禁止する

Definition of done:

- [ ] RL を始める前に SFT / DPO / reranker の結果が揃っている

## 直近で切るIssue候補

1. `Add fast-context eval case schema and seed fixtures`
2. `Add dogfood log aggregator for fast-context outcomes`
3. `Break down Zenz review-unavailable reasons`
4. `Add feature breakdown for AIReranker.localScore`
5. `Document Zenz provenance and license obligations`
6. `Prototype zenz-v3.1-xsmall HF evaluation script`
7. `Prototype LoRA smoke training for zenz-v3.1-xsmall`
8. `Document GGUF conversion and bundle replacement workflow`

## 次の一手

最初に実装するなら以下の順番。

1. `M2-1 dogfood log aggregator`
2. `M1-1 eval case schema`
3. `M1-2 seed eval set 30件から開始`
4. `M2-2 review-unavailable reason breakdown`
5. `M3-1 feature breakdown`

理由:

- 今すでに model backend ON で dogfood しているため、ログ集計の価値が即出る。
- fine-tuning より前に、何を改善すべきかを数値で見られるようにする必要がある。
