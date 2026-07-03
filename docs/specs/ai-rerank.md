# Spec: AI Rerank

> Trigger: AIReranker.swift, CandidateGenerator.swift, ExternalCommandAIReranker, GyaimController AI rerank integration
> Last updated: 2026-07-04 (文脈条件付き学習・同音異義語直接logprob比較・accepted rank計測)

## 概要

SwiftyGyaim の既存候補に、Tab 明示起動でローカル複合候補・補完候補を加え、ローカル AI reranker で候補順を補正する。

初段は Swift in-process heuristic rerank を使う。アプリ同梱の `zenz-v3.1-xsmall-gguf` GGUF モデルも bundle resource として持ち、IMEプロセス内で memory-map / llama.cpp context として保持する。`LlamaZenzContext` は tokenization / `llama_decode` / logits 取得を行い、候補文字列の平均 log probability を score に混ぜる。また azooKey/Zenzai の `ZenzCandidateEvaluator` と同様に、候補 token とモデル最尤 token を比較して mismatch 時に prefix constraint を抽出し、pass 時には高確率 alternative prefix を収集する。Python resident server / external command の GPT-2 rerank は legacy 比較用で、既定では起動しない。Google Input Tools は候補追加ソースとして使う。

## 目的

- 既存の Study / Local / Connection / synthetic 候補を壊さずに AI の判断を加える
- Tab 明示起動時だけローカル複合候補・補完候補を追加する。Google候補はsuffix/shortcut、またはTab pipelineの明示opt-inで追加する
- AI response は候補 index の順序だけを返す。候補文字列の追加は Swift 側 candidate generator が行う
- 失敗・timeout・不正レスポンス時は元候補順に fallback する
- raw input は候補0に残し、Tab後も未確定本文をローマ字のまま維持する
- ローカルモデルを使い、通常のrerankではcloud送信を避ける。Google候補はsuffix/shortcut、または明示opt-in時だけ optional source として扱う

## 設定

Tab時の初段 rerank は `InProcessAIReranker` で常に実行する。これは HTTP / external command を使わないためプロセス境界がなく、server 未起動でも即時に候補順を補正できる。

同梱モデルは以下の app bundle resource として配置する。

```text
Resources/Models/zenz-v3.1-xsmall-gguf/ggml-model-Q5_K_M.gguf
```

`InProcessAIReranker` は `AIRerankBackend` を優先順に試す。既定では `BundledZenzAIRerankBackend` が `BundledZenzRuntime` を通じて `BundledAIRerankModel` を prepare し、同梱GGUFを memory-map してIMEプロセス内で保持する。`llama` module が link されている場合は `LlamaZenzContext` が model/context/vocab を resident にし、Zenz v3 control tag prompt に続く candidate text の token 平均 log probability を Swift heuristic score に加算する。Zenz scoring は体感速度のため既定で上位8件に制限し、raw input は候補0維持のため scoring 対象から除外する。ただし Zenz generation / review 由来の `kind=zenz` 候補は、ログ由来の `kyoukaisen -> 境界線` のように候補集合の末尾へ追加されることがあるため、上位8件の外でも scoring 対象に含める。`aiRerankUseBundledZenz=false` で Zenz を明示無効化できる。

Google Input Tools は後追い補助として optional に使う。Google込みの2段階更新は候補ウィンドウの再描画が目立つため既定では無効で、`aiRerankUseGoogle=true` を明示した場合だけ実行する。GPT-2 resident server への直接HTTP接続、または external command は legacy 比較用で、`aiRerankUseLegacyExternalReranker=true` を明示した場合だけ Swift/Zenz の後に追加で非同期実行される。

- Zenz scoring weight: `aiRerankZenzWeight`（未設定時 0.30）
- Zenz scoring candidates: `aiRerankZenzMaxCandidates`（未設定時 8、rawは除外）
- Zenz generation beam: `aiRerankZenzGenerationBeamWidth`（未設定時 1、最大 6）
- Zenz review rounds: `aiRerankZenzReviewRounds`（未設定時 2、最大 3）
- Zenz alternative limit: `aiRerankZenzAlternativeLimit`（未設定時 2、最大 4）
- exact同音異義語margin: `aiRerankExactHomophoneMargin`（未設定時 0.10、平均logprob単位）
- exact同音異義語比較候補数: `aiRerankExactHomophoneMaxCandidates`（未設定時 3、最大 6）
- legacy opt-in 設定キー: `aiRerankUseLegacyExternalReranker=true`
- legacy HTTP 設定キー: `aiRerankServerURL`
- legacy HTTP env: `GYAIM_AI_RERANK_SERVER`
- legacy command 設定キー: `aiRerankCommand`
- legacy command env: `GYAIM_AI_RERANK_COMMAND`

Legacy HTTP timeout は設定キー `aiRerankHTTPTimeoutMs` で指定する。未設定時は 1200ms。External command timeout は `aiRerankTimeoutMs` で指定する。設定画面で扱う値と同じく `~/.gyaim/settings.json` を優先し、既存UserDefaults値は後方互換fallbackとして読む。

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
    {"index": 0, "text": "昨日", "reading": "kinou", "source": "study", "kind": "exact", "studyFrequency": 3},
    {"index": 1, "text": "機能", "reading": "kinou", "source": "connection", "kind": "exact", "contextAffinity": 0.75},
    {"index": 2, "text": "きのう", "reading": null, "source": "synthetic", "kind": "kana"}
  ]
}
```

候補の `contextAffinity`（0.0〜1.0、ContextDictの文脈一致度）と `studyFrequency`（study辞書の使用回数）は optional。省略時は評価に影響しない。

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
- `compound`: 旧CandidateGeneratorの複合候補（互換用）
- `lattice`: CandidateGenerator の lattice/Viterbi 風候補
- `completion`: CandidateGenerator の語尾補完候補
- `zenz`: 同梱Zenzの制約付きgreedy生成候補
- `google`: Google Input Tools 候補
- `kana`: ひらがな/カタカナ候補

## In-process local rerank scoring

Swift heuristic rerank は source bias / kind bias / reading一致 / 漢字含有 / script transition penalty を足し合わせる。raw input は候補0に保持するが、ランキング上は強い負スコアを与える。完全一致読み (`kind=exact` かつ `reading == inputPat`) は、prefix / lattice のノイズより優先されるよう追加 bonus を与える。ただし `決して` / `絶対に` / `してはいけ` / `してはなら` / `禁止` / `だめ` / `ダメ` / `ないで` のような強い禁止・否定命令 cue が左文脈にあり、prefix 候補が `な` で終わる場合は contextPredictionBonus で prefix 候補を上げる。一方で、`masen` を明示的に入力しておらず、左文脈にも否定 cue がない段階では、`お願いします` / `思います` への途中入力で `お願いしません` / `思いません` が先頭化しないよう polite negative prediction penalty を与える。さらに `漢字 + の + 漢字` や文末 `では` / `には` / `とは` のような機能語を含む自然なphraseに bonus を与え、ログ由来の `imanodankaideha -> 今の段階では` のような長文候補を、固定phrase辞書なしでも `今野...` 系のprefix複合より上げる。同じ読み・同種候補で句読点付きが元順だけで勝つのを避けるため、文末 `？` / `！` には小さな penalty を与える。一方、`ha?` のように inputPat が `?` / `!` で終わる場合は、対応する句読点を含まない候補に `punctuatedInputMismatchPenalty` を与え、`投機的デコーディング` のような長い local/study 候補が `は？` より上がらないようにする。さらに、同じ候補集合に完成形がある未完成語幹へ `incompleteStemPenalty` を与える。対象は `少な -> 少ない` / `くださ -> ください` のような末尾 `い` 欠落と、`使っ -> 使った` / `言っ -> 言って` のような促音 `っ` 終わり語幹（日本語の語は `っ` で終わらないため誤爆しない）の2クラス。`ため -> ために` や `する -> するな` のような正当な短縮形は penalize しない。Zenz generation / review 由来の全漢字語には小さな追加 bonus を与え、`kyoukaisen -> 境界線` のようにモデルが示した全漢字候補が `教会せん` などの混在script lattice候補に埋もれないようにする。

文脈条件付き学習（ADR-020）として、確定時に `(左文脈末尾8文字, reading, word)` を `~/.gyaim/contextdict.txt` に記録し、rerank時に同じ (reading, word) の文脈suffix一致度を `contextAffinity`（suffix共通長2文字以上で発火、4文字で1.0に飽和）として候補に付与する。`AIReranker` は `contextAffinityBonus = min(affinity, 1.0) * 1.50` を加点し、`向き` / `無機` のような同音異義語をユーザー履歴からモデルなしで選べるようにする。また study 候補には `studyFrequency` を渡し、`studyFrequencyBonus = min(0.30, log2(frequency) * 0.10)`（frequency 2以上で発火）でフラットな sourceBias を頻度で補正する。

Swift runtime 側でも `AIReranker.localScoreBreakdown(candidate:request:)` が feature contribution と total score を返す。これにより、offline evaluator の `--show-features` と同じ観点で source bias / kind bias / exact reading bonus / prefix penalty / context bonus / context affinity bonus / study frequency bonus / kanji bonus / natural phrase bonus / punctuation penalty / punctuated input mismatch penalty / incomplete stem penalty / script transition penalty / zenz kanji bonus / raw ASCII penalty をテスト・debug できる。

## CandidateGenerator lattice scoring

Tab 時の追加候補は lattice/Viterbi 風の beam search で生成し、読み全体を複数 segment に分割して候補列を探索する。単純な辞書連結よりも azooKey/Zenzai 型の「候補集合を作ってから rerank」に寄せるため、候補には `kind=lattice` を付ける。

暫定 cost / score は以下を反映する。

- segment reading length（長い一致を優先）
- segment count penalty（細切れ分割を下げる）
- source bias（study/local/connection）
- 1文字漢字segment penalty
- 不自然な script transition penalty（例: ひらがな終端 + 漢字開始、カタカナ + ひらがな）
- segmentの文字種フィルタ（かな・カナ・漢字・全角英数などを許可し、数学記号等を除外）
- 短い読みの数値segment抑制（例: 長文lattice内の `go -> ５` / `五` ノイズを除外）
- `漢字語 + する` bonus
- ログで観測された一般的な複合語 bonus（例: `起動 + 後`）

これにより `追う集する` / `追う集スる` のような単純連結候補を下げ、`押収する` のようなまとまりのある候補を優先する。また `ん∩か` のような辞書由来の記号segment連結や、`次回起動５` のような短い数値segment連結は生成段階で除外する。短い入力（例: `nise`）では lattice 分割がノイズになりやすいため生成しない。

## Zenz candidate evaluation and constraints

Tab 候補集合を作った後、同梱Zenzで候補を評価する。azooKey/Zenzai と同じ方針で、candidate evaluation prompt に続く候補 token を1つずつ見て、モデル最尤 token と実候補 token が一致しない場合は `fixRequired(prefixConstraint:)` 相当の prefix を返す。一致している場合は、次点 token の確率比を alternative constraint として保持する。

SwiftyGyaim ではまず Swift local rerank の順で上位候補を評価し、fixRequired prefix が出たらその prefix で `CandidateGenerator` の lattice を再探索する。pass 時の alternative constraint は確率比 `> 0.25` のものだけを補助候補として使う。追加候補が得られた場合は、更新された候補集合でもう一度 candidate evaluation を行う。現時点の review loop は既定2 round、設定キー `aiRerankZenzReviewRounds` で最大3 roundまで調整可能とし、azooKey のような `fixRequired -> prefix constraint付きlattice再探索 -> 再評価` の形へ寄せる。これは自由生成で候補を広げるのではなく、Zenz の評価結果で lattice 再探索を誘導するための経路である。

fast-context rerank の model opt-in 経路では latency と安全性を優先し、Swift heuristic の最上位候補だけを1回 review する。`fixRequiredPrefix` は既存候補に prefix 一致する場合だけ先頭移動に使うが、通常のprefix予測では1文字 prefix を採用しない（`こうほ -> 高品質` や `つか... -> つかっちゃ` のような広すぎる置換を誘発しやすいため）。また現在の最上位候補自身に一致する prefix は順位変更として扱わず、local order を維持する。

読み完全一致の `.exact` / `.compound` 最上位候補は、原則として model review で prefix 予測候補へ沈めない。ただし、左文脈があり、同じ読みの `.exact` / `.compound` 候補が複数ある場合（例: `muki` の `向き` / `無機`、`kinou` の `機能` / `昨日`）は exact 同音異義語レビューとして扱う（ADR-021）。この場合は `fixRequiredPrefix` 経由の置換ではなく、`exactHomophoneCandidateIndices` が返す protected exact 候補（既定上位3件、`aiRerankExactHomophoneMaxCandidates` で最大6）を `LlamaZenzContext.score` の条件付き平均logprobで**直接比較**する。未完成語幹（候補集合内に `語幹+い` または `っ` 終わり語幹の完成形が存在する候補、例: `ください` があるときの `くださ`）は比較対象から除外するため、モデルが未完成候補を昇格させることは構造上できない。勝者が現在のbestを margin（`aiRerankExactHomophoneMargin`、既定0.10）以上上回った場合のみ先頭を入れ替える。ログ outcome は `exact-homophone-fixed`（入れ替え）/ `exact-homophone-kept-local`（勝者が別候補だがmargin不足）/ `exact-homophone-passed`（bestが勝者）/ `exact-homophone-unavailable`（scoring失敗）を使う。

candidate evaluation で モデル最尤 token が EOS の場合（モデルが「ここで文が完結する」と判断したケース）は、failure ではなく pass として扱う。dogfood（2026-07）では `review-unavailable` の437/437件がこの `best-token-is-eos` であり、1回あたり約25msの無駄撃ちと誤った警告ログになっていた。この信号から短縮置換は行わない（未完成語幹昇格の危険があるため）。

## Zenz candidate generation

`aiRerankUseZenzGeneration` が未設定または `true` の場合、Tab 時に同梱Zenzへ `inputTag + 読み + outputTag` prompt を渡し、最大12 token の greedy generation を1候補だけ試す。生成結果は以下の安全フィルタを通った場合のみ `kind=zenz` として候補集合に追加する。

- 空文字、raw input と同一、16文字超は除外
- かな・カナ・漢字等の日本語文字を含まないものは除外
- 制御タグ・改行以降は切り捨て
- 許可文字種外の記号を含むものは除外

この経路は、辞書にない候補をZenzから候補集合へ入れるための第一段階である。ただし完全自由生成はIME候補として危険なため、現時点では1候補・短文・文字種制約付きに限定する。

## Validation

SwiftyGyaim 本体は `order` を必ず検証する。

- 範囲外 index は無視
- 重複 index は無視
- 欠落 index は元順で末尾に追加
- candidateCount が 0 の場合は空配列

これにより、AI が不正な順序を返しても候補を失わない。

## 実行フロー

AI候補生成は通常入力では自動実行しない。IME の体感速度を優先し、ユーザーが問題だと思った候補一覧に対して Tab で明示的に起動する。通常入力中の候補順補正は fast-context rerank が担うため、Shift+Tab / `` ` `` の rerank-only shortcut は廃止する。

```text
searchAndShowCands()
  -> 既存辞書で candidates を生成
  -> nthCand = 0
  -> showCands() で即時表示

Tab while converting
  -> requestAIRerankIfAvailable()
       -> CandidateGenerator でローカル lattice 候補 / 補完候補を生成
       -> 同梱Zenzの制約付きgreedy生成候補を追加
       -> InProcessAIReranker（AIRerankBackend: 同梱Zenz保持 + Swift heuristic）で即 rerank
       -> raw input を候補0に戻して候補一覧へ反映
       -> `aiRerankUseLegacyExternalReranker=true` なら GPT-2 server / external command で後追い再rerank
       -> `aiRerankUseGoogle=true` の場合だけ Google Input Tools API が返ったら候補集合へ追加
       -> Google込みでも InProcessAIReranker で即 rerank（明示 opt-in 時のみ2回目の候補更新が発生）
       -> `aiRerankUseLegacyExternalReranker=true` なら GPT-2 server / external command で後追い再rerank
       -> response order を検証
       -> stale guard / revision guard
       -> raw input を候補0に戻して candidates を更新
       -> showCands() / showWindow()

Google Transliterate suffix/shortcut while converting
  -> triggerGoogleTransliterate()
       -> 読みをひらがな化して Google Input Tools API に送る
       -> Google候補・ひらがな・カタカナ候補を `searchMode=2` で表示する
       -> pendingGoogleQuery / inputPat による stale guard で古い応答を破棄する
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

dogfood中は確定のたびに `Fast context accepted: input=... word=... rank=N candidates=M source=... kind=...` を出力し（`aiRerankFastContextLoggingEnabled=true` 時のみ、prefix mode・意図的確定のみ）、`aggregate-fast-context-log.py` の `acceptedRanks` セクションが rank分布・acceptedTop1Rate / acceptedTop3Rate を集計する。これはユーザーの実入力に対する top1/top3 accuracy の代替指標で、eval fixture のチューニングが実使用と乖離していないかを常時監視する。

feature weight の学習には `train-fast-context-weights.py` を使う。eval fixture（または同スキーマのpreference JSONL）から `expectedTop` vs 他候補の pairwise logistic regression で feature multiplier を学習し（1.0初期値・1.0方向へL2正則化・非負クランプ）、`--feature-weight` 引数として出力する。`model-required` タグ（heuristic featureでは解けない文脈依存同音異義語）は既定で学習から除外する。

量子化の影響は `Tools/zenz-tuning/compare-hf-gguf.py`（M4-1）で計測する。HF非量子化モデルと GGUF Q5_K_M を同じ eval fixture・同じ条件付き平均logprob scoringで比較し、top1一致率・Kendall tau距離を出す（transformers / llama-cpp-python は backend別 opt-in 依存）。

実ログから、azooKey の `anco evaluate` と同様に query / answer / outputs / rank を評価するデータを作る。SwiftyGyaim 内部ループでは JSONL を使い、azooKey 側との比較には `--azookey-json` で `anco evaluate` 互換JSONも出力できる。ログの確定結果を学習辞書として再生する場合は `--study-dict` で SwiftyGyaim study TSV を作る。

```bash
cd GyaimSwift
Tools/eval/extract-ime-log-cases.py \
  --log ~/.gyaim/gyaim.log \
  --jsonl /tmp/gyaim-ime-cases.jsonl \
  --azookey-json /tmp/gyaim-azookey-eval.json \
  --study-dict /tmp/gyaim-feedback-studydict.txt
```

固定fixtureでアプリ外の候補生成 + rerank ループを検証する場合は以下を使う。入力fixtureは `Tests/GyaimTests/Fixtures/candidate-feedback-cases.json` に置き、top5 / learnedTop1 / zenzTop5 の期待順位をテストする。Zenz込み検証では base generation / Zenz generation / review loop / final rerank の latency breakdown、review round数、review追加候補数を `/tmp/gyaim-candidate-feedback-report.md` に出力する。`RUN_ZENZ=0` で重いZenz込み検証をskipできる。

```bash
cd GyaimSwift
Tools/eval/run-candidate-feedback.sh
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
- 同梱 GGUF モデルは llama.cpp decode/logits scoring と prefix constraint / alternative constraint 抽出まで接続済み。ただし azooKey本体の lattice / personalization / version-dependent evaluation と完全同等ではない
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
