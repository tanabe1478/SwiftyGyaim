# Spec: AI Rerank

> Trigger: AIReranker.swift, CandidateGenerator.swift, ExternalCommandAIReranker, GyaimController AI rerank integration
> Last updated: 2026-05-22

## 概要

SwiftyGyaim の既存候補に、Tab 明示起動でローカル複合候補・補完候補を加え、ローカル AI reranker で候補順を補正する。

初段は Swift in-process heuristic rerank を使う。アプリ同梱の `zenz-v3.1-xsmall-gguf` GGUF モデルも bundle resource として持ち、IMEプロセス内で memory-map / llama.cpp context として保持する。`LlamaZenzContext` は tokenization / `llama_decode` / logits 取得を行い、候補文字列の平均 log probability を score に混ぜる。Python resident server / external command の GPT-2 rerank は legacy 比較用で、既定では起動しない。Google Input Tools は候補追加ソースとして使う。

## 目的

- 既存の Study / Local / Connection / synthetic 候補を壊さずに AI の判断を加える
- Tab 明示起動時だけローカル複合候補・補完候補・Google候補を追加する
- AI response は候補 index の順序だけを返す。候補文字列の追加は Swift 側 candidate generator が行う
- 失敗・timeout・不正レスポンス時は元候補順に fallback する
- raw input は候補0に残し、Tab後も未確定本文をローマ字のまま維持する
- ローカルモデルを使い、cloud 送信を避ける。Google候補は明示Tab時のみ optional source として扱う

## 設定

Tab時の初段 rerank は `InProcessAIReranker` で常に実行する。これは HTTP / external command を使わないためプロセス境界がなく、server 未起動でも即時に候補順を補正できる。

同梱モデルは以下の app bundle resource として配置する。

```text
Resources/Models/zenz-v3.1-xsmall-gguf/ggml-model-Q5_K_M.gguf
```

`InProcessAIReranker` は `AIRerankBackend` を優先順に試す。既定では `BundledZenzAIRerankBackend` が `BundledZenzRuntime` を通じて `BundledAIRerankModel` を prepare し、同梱GGUFを memory-map してIMEプロセス内で保持する。`llama` module が link されている場合は `LlamaZenzContext` が model/context/vocab を resident にし、Zenz v3 control tag prompt に続く candidate text の token 平均 log probability を Swift heuristic score に小さく加算する。`aiRerankUseBundledZenz=false` で Zenz を明示無効化できる。

Google Input Tools は後追い補助として使う。Google込みの2段階更新は `aiRerankUseGoogle=false` で明示無効化できる。GPT-2 resident server への直接HTTP接続、または external command は legacy 比較用で、`aiRerankUseLegacyExternalReranker=true` を明示した場合だけ Swift/Zenz の後に追加で非同期実行される。

- legacy opt-in UserDefaults: `aiRerankUseLegacyExternalReranker=true`
- legacy HTTP UserDefaults: `aiRerankServerURL`
- legacy HTTP env: `GYAIM_AI_RERANK_SERVER`
- legacy command UserDefaults: `aiRerankCommand`
- legacy command env: `GYAIM_AI_RERANK_COMMAND`

Legacy HTTP timeout は UserDefaults `aiRerankHTTPTimeoutMs` で指定する。未設定時は 1200ms。External command timeout は `aiRerankTimeoutMs` で指定する。

Legacy GPT-2 を比較目的で明示的に動かす例:

```bash
defaults write com.pitecan.inputmethod.SwiftyGyaim aiRerankUseLegacyExternalReranker -bool true
defaults write com.pitecan.inputmethod.SwiftyGyaim aiRerankServerURL "http://127.0.0.1:8765/rerank"
defaults write com.pitecan.inputmethod.SwiftyGyaim aiRerankHTTPTimeoutMs 1200
```

## Request JSON

SwiftyGyaim は external command の stdin に JSON を渡す。

```json
{
  "version": 1,
  "mode": "rerank",
  "inputPat": "kinou",
  "hiragana": "きのう",
  "context": "直前に確定した文脈",
  "candidates": [
    {"index": 0, "text": "昨日", "reading": "kinou", "source": "study", "kind": "exact"},
    {"index": 1, "text": "機能", "reading": "kinou", "source": "connection", "kind": "exact"},
    {"index": 2, "text": "きのう", "reading": null, "source": "synthetic", "kind": "kana"}
  ]
}
```

## Response JSON

External command は stdout に JSON を返す。

```json
{
  "order": [1, 0, 2],
  "scores": {
    "0": -0.42,
    "1": -0.31,
    "2": -0.88
  },
  "model": "ku-nlp/gpt2-small-japanese-char"
}
```

`order` は候補 index の配列。新しい候補文字列は返さない。追加候補は SwiftyGyaim 側で request 作成前に生成する。

## Candidate metadata

`source` は候補の出自、`kind` は候補の性質を表す。`kind` は以下の値を取る。

- `raw`: ローマ字そのまま
- `exact`: 読み完全一致の辞書候補
- `prefix`: 前方一致の辞書候補
- `compound`: CandidateGenerator の複合候補
- `completion`: CandidateGenerator の語尾補完候補
- `google`: Google Input Tools 候補
- `kana`: ひらがな/カタカナ候補

## CandidateGenerator scoring

複合候補は beam search で生成し、以下を暫定的に score へ反映する。

- segment reading length（長い一致を優先）
- segment count penalty（細切れ分割を下げる）
- source bias（study/local/connection）
- 1文字漢字segment penalty
- 不自然な script transition penalty（例: ひらがな終端 + 漢字開始、カタカナ + ひらがな）
- `漢字語 + する` bonus

これにより `追う集する` / `追う集スる` のような単純連結候補を下げ、`押収する` のようなまとまりのある候補を優先する。

## Validation

SwiftyGyaim 本体は `order` を必ず検証する。

- 範囲外 index は無視
- 重複 index は無視
- 欠落 index は元順で末尾に追加
- candidateCount が 0 の場合は空配列

これにより、AI が不正な順序を返しても候補を失わない。

## 実行フロー

AI rerank は通常入力では自動実行しない。IME の体感速度を優先し、ユーザーが問題だと思った候補一覧に対して Tab / Shift+Tab で明示的に起動する。

```text
searchAndShowCands()
  -> 既存辞書で candidates を生成
  -> nthCand = 0
  -> showCands() で即時表示

Tab while converting
  -> requestAIRerankIfAvailable()
       -> CandidateGenerator でローカル複合候補 / 補完候補を生成
       -> InProcessAIReranker（AIRerankBackend: 同梱Zenz保持 + Swift heuristic）で即 rerank
       -> raw input を候補0に戻して候補一覧へ反映
       -> `aiRerankUseLegacyExternalReranker=true` なら GPT-2 server / external command で後追い再rerank
       -> `aiRerankUseGoogle != false` の場合 Google Input Tools API が返ったら候補集合へ追加
       -> Google込みでも InProcessAIReranker で即 rerank
       -> `aiRerankUseLegacyExternalReranker=true` なら GPT-2 server / external command で後追い再rerank
       -> response order を検証
       -> stale guard / revision guard
       -> raw input を候補0に戻して candidates を更新
       -> showCands() / showWindow()

Shift+Tab or ` while converting
  -> requestAIRerankOnlyIfAvailable()
       -> 現在の候補集合を InProcessAIReranker で即 rerank する。legacy opt-in 時のみ HTTP server または external command にも送る
       -> 候補追加・Google API・複合候補生成は行わない
       -> response order を検証
       -> stale guard / revision guard
       -> raw input を候補0に戻して candidates を更新
       -> showCands() / showWindow()
```

## Stale Guard

AI rerank は非同期で返るため、request 発行時の `inputPat` を `pendingAIRerankQuery` に保存する。

callback 時に以下を確認する。

- `pendingAIRerankQuery == query`
- 現在の `inputPat == query`
- `searchMode == 0`

一致しない場合は古い結果として破棄する。

## 初期 provider: ku-nlp GPT-2 char reranker

同梱 script:

```text
GyaimSwift/Tools/ai-rerank/gyaim-gpt2-char-rerank.py          # 単発実行版
GyaimSwift/Tools/ai-rerank/gyaim-gpt2-char-rerank-server.py   # resident server
GyaimSwift/Tools/ai-rerank/gyaim-gpt2-char-rerank-client.py   # resident server client
```

利用モデル:

```text
ku-nlp/gpt2-small-japanese-char
```

特徴:

- 日本語 character-level GPT-2 small
- 約90M parameters
- 候補生成ではなく language model scoring に使う
- 各候補について `読み + 変換:` に続く自然さを score する
- source bias / kind bias を少し加え、synthetic/raw input や prefix/completion が勝ちすぎないようにする

依存:

```bash
python3 -m pip install -r Tools/ai-rerank/requirements.txt
```

初回実行では Hugging Face からモデルを download / cache するため遅い。実用時は resident server を起動し、IME からは `GYAIM_AI_RERANK_SERVER` / `aiRerankServerURL` で直接HTTP接続する。

## Resident server 運用

毎回モデルをロードすると IME 用途では遅すぎるため、常用時は resident server を使う。

起動:

```bash
cd GyaimSwift
python3 Tools/ai-rerank/gyaim-gpt2-char-rerank-server.py
```

別 terminal で疎通確認:

```bash
curl http://127.0.0.1:8765/health
```

SwiftyGyaim 側設定:

```bash
# 推奨: Swift本体から resident server へ直接HTTP接続（client process起動コストなし）
export GYAIM_AI_RERANK_SERVER="http://127.0.0.1:8765/rerank"
# または
# defaults write com.pitecan.inputmethod.SwiftyGyaim aiRerankServerURL "http://127.0.0.1:8765/rerank"

# fallback / protocol検証用: external command client
# export GYAIM_AI_RERANK_COMMAND="$PWD/Tools/ai-rerank/gyaim-gpt2-char-rerank-client.py"
```

port を変える場合:

```bash
GYAIM_GPT2_RERANK_PORT=9876 python3 Tools/ai-rerank/gyaim-gpt2-char-rerank-server.py
export GYAIM_AI_RERANK_SERVER=http://127.0.0.1:9876/rerank
# external command client を使う場合のみ:
# GYAIM_GPT2_RERANK_SERVER=http://127.0.0.1:9876/rerank Tools/ai-rerank/gyaim-gpt2-char-rerank-client.py
```

## 評価ループ

実ログから評価データを作る。

```bash
cd GyaimSwift
Tools/ai-rerank/extract-gyaim-log-training-data.py \
  --out /tmp/gyaim-rerank.jsonl \
  --max-candidates 12
```

resident server を起動した状態で、評価 runner から評価する。実用 latency を見る場合は `--server-url` で直接HTTP接続する。external command client 経由の評価は protocol 検証用。

```bash
Tools/ai-rerank/evaluate-reranker.py \
  /tmp/gyaim-rerank.jsonl \
  --server-url http://127.0.0.1:8765/rerank \
  --limit 200 \
  --top-n 10 \
  --report /tmp/gyaim-rerank-report.md
```

external command client 経由で評価する場合:

```bash
Tools/ai-rerank/evaluate-reranker.py \
  /tmp/gyaim-rerank.jsonl \
  --command "$PWD/Tools/ai-rerank/gyaim-gpt2-char-rerank-client.py" \
  --limit 200 \
  --top-n 10
```

評価 summary は baseline top1/top3、rerank top1/top3、latency p50/p95、改善・悪化件数を出す。2026-05-22 の手元ログ200件では、直接HTTPで baseline top1 2.0% → rerank top1 87.0%、top3 99.0%維持、latency p50 31.6ms / p95 40.5ms。

## 既知の制約

- Swift in-process heuristic は高速だが、文脈LMではないため自然文としての文脈判断は GPT-2 より弱い
- 同梱 GGUF モデルは llama.cpp decode/logits scoring まで接続済みだが、prefix constraint / rich alternative evaluation はまだ未実装
- 同梱 `zenz-v3.1-xsmall-gguf` は CC-BY-SA-4.0 ライセンス
- resident server 起動時の初回モデル download / load は遅い
- resident server を起動していない場合、GPT-2 rerank は行われないが、Swift heuristic の結果は表示される
- 単発実行版 `gyaim-gpt2-char-rerank.py` は毎回モデルをロードするため、主に protocol 検証用
- IME 本体は timeout で fallback するため入力は止まらない。timeout時も Swift heuristic の結果は残る
- `ku-nlp/gpt2-small-japanese-char` は CC-BY-SA-4.0 ライセンス。Python GPT-2 をアプリ同梱配布する場合はライセンス影響を別途確認する
- 現時点では周辺文脈を渡していない
- Python client process 起動コストを避けるため、GPT-2を使う場合は `GYAIM_AI_RERANK_SERVER` / `aiRerankServerURL` による Swift 直接HTTP接続を推奨する

## 将来拡張

- resident server の launchd plist / 設定 UI 連携
- MLX / Core ML / llama.cpp での高速化
- SwiftyGyaim の確定ログを使った fine-tuning
- app bundle / profile / 直近確定語を context に追加
- rerank 前後とユーザー選択結果の評価ログ
- 手動 rerank shortcut / 自動 rerank の設定分離
