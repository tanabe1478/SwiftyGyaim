# Spec: AI Rerank

> Trigger: AIReranker.swift, ZenzRuntime.swift, InProcessAIReranker.swift, AIRerankBackend.swift, GyaimController の fast-context rerank
> Last updated: 2026-09-12 (ADR-024 以降の現状に合わせて全面更新。Tab パイプライン・GPT-2 server の記述を廃止扱いに)

## 概要

通常入力（prefix mode）の候補順を、Swift heuristic と同梱の小型言語モデルで補正する（fast-context rerank）。モデルは `Resources/Models/gyaim-lm-small-public-v1-gguf/ggml-model-Q5_K_M.gguf`（`customModelPath` で差し替え可、後述）を IME プロセス内で memory-map し、`LlamaZenzContext` が tokenization / `llama_decode` / logits 取得と、候補文字列の条件付き平均 log probability の算出を行う。

かつて存在した Tab 起動のローカル候補生成パイプライン（CandidateGenerator の lattice / 補完候補、Zenz 制約付き生成、review loop）は ADR-024 で削除され、Tab は Google 変換の起動になった。Python resident server / external command による GPT-2 rerank も Swift 側の呼び出し元がなく、legacy として扱う（末尾「Legacy」参照）。

## 目的

- 既存の Study / Local / Connection / synthetic 候補を壊さずに順序だけを補正する。候補文字列は追加しない
- rerank 応答は候補 index の順序だけを返し、本体が必ず検証する（Validation）
- raw input は候補 0 に残す
- 通常入力ではモデルをローカルで動かし、クラウド送信をしない（Google 変換は明示起動のみ）
- 打鍵のレイテンシを優先する: heuristic は同期、モデルは遅延実行（ADR-026）

## 設定

`InProcessAIReranker` は `AIRerankBackend` を優先順に試す。既定では `BundledZenzAIRerankBackend` が `BundledZenzRuntime` を通じて `BundledAIRerankModel` を prepare し、同梱 GGUF を memory-map して IME プロセス内で保持する。`llama` module が link されている場合は `LlamaZenzContext` が model / context / vocab を resident にする。モデルが用意できない場合は `HeuristicAIRerankBackend` にフォールバックする。全件 rerank（`mode=rerank`）では候補ごとの平均 logprob を採点集合の平均との差分（mean-centering、BUG-029）として heuristic score に加算するが、通常入力で使う `mode=fast-context-rerank` は後述のレビュー方式で最上位候補だけを見る。

主な設定キー（全キー・既定値は `docs/specs/settings.md` を正とする）:

- `aiRerankFastContextEnabled` / `aiRerankUseModelForFastContext` / `aiRerankFastContextLoggingEnabled`（設定画面）
- `aiRerankUseBundledZenz`（設定画面。OFF でモデル経路を使わない）
- `aiRerankFastContextReviewDelayMs`（既定 80、ADR-026）
- `aiRerankExactHomophoneMargin` / `aiRerankExactHomophoneMaxCandidates` / `aiRerankExactHomophoneAffinityThreshold` / `aiRerankExactHomophoneFrequencyMarginWeight`
- `aiRerankZenzWeight` / `aiRerankZenzMaxCandidates`（全件 rerank 用）
- `customModelPath`（モデル差し替え）

`aiRerankUseZenzGeneration` / `aiRerankZenzGenerationBeamWidth` / `aiRerankConstrainedSelectionMaxSurfaces` は ADR-022 の辞書制約付き生成用で、ADR-024 以降は到達経路がない（設定画面のトグルも効果なし。削除はフォローアップ）。

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

`source` は候補の出自、`kind` は候補の性質を表す。`kind` は以下の値を取る（enum は eval fixture との互換のため削除済み経路の値も保持する）。

- `raw`: ローマ字そのまま
- `exact`: 読み完全一致の辞書候補（かな等価の読みを含む、BUG-026）
- `prefix`: 前方一致の辞書候補
- `compound`: connection dict の複数エントリ合成候補
- `lattice` / `completion` / `zenz`: 削除済みの Tab パイプライン由来（ADR-024）。現在は生成されないが、fixture と heuristic の `zenzKanjiBonus` のため値は残る
- `google`: Google Input Tools 候補
- `kana`: ひらがな/カタカナ候補

## In-process local rerank scoring

Swift heuristic rerank は source bias / kind bias / reading一致 / 漢字含有 / script transition penalty を足し合わせる。raw input は候補0に保持するが、ランキング上は強い負スコアを与える。完全一致読み (`kind=exact` かつ `reading == inputPat`) は、prefix / lattice のノイズより優先されるよう追加 bonus を与える。ただし `決して` / `絶対に` / `してはいけ` / `してはなら` / `禁止` / `だめ` / `ダメ` / `ないで` のような強い禁止・否定命令 cue が左文脈にあり、prefix 候補が `な` で終わる場合は contextPredictionBonus で prefix 候補を上げる。一方で、`masen` を明示的に入力しておらず、左文脈にも否定 cue がない段階では、`お願いします` / `思います` への途中入力で `お願いしません` / `思いません` が先頭化しないよう polite negative prediction penalty を与える。さらに `漢字 + の + 漢字` や文末 `では` / `には` / `とは` のような機能語を含む自然なphraseに bonus を与え、ログ由来の `imanodankaideha -> 今の段階では` のような長文候補を、固定phrase辞書なしでも `今野...` 系のprefix複合より上げる。同じ読み・同種候補で句読点付きが元順だけで勝つのを避けるため、文末 `？` / `！` には小さな penalty を与える。一方、`ha?` のように inputPat が `?` / `!` で終わる場合は、対応する句読点を含まない候補に `punctuatedInputMismatchPenalty` を与え、`投機的デコーディング` のような長い local/study 候補が `は？` より上がらないようにする。さらに、同じ候補集合に完成形がある未完成語幹へ `incompleteStemPenalty` を与える。対象は `少な -> 少ない` / `くださ -> ください` のような末尾 `い` 欠落と、`使っ -> 使った` / `言っ -> 言って` のような促音 `っ` 終わり語幹（日本語の語は `っ` で終わらないため誤爆しない）の2クラス。`ため -> ために` や `する -> するな` のような正当な短縮形は penalize しない。また、stemが既に `い` で終わる場合は「いの欠落」という前提が成り立たないため対象外とする（BUG-025: typo由来の `してほしいい` が `してほしい` を沈めた）。Zenz generation / review 由来の全漢字語には小さな追加 bonus を与え、`kyoukaisen -> 境界線` のようにモデルが示した全漢字候補が `教会せん` などの混在script lattice候補に埋もれないようにする。

文脈条件付き学習（ADR-020）として、確定時に `(左文脈末尾8文字, reading, word)` を `~/.gyaim/contextdict.txt` に記録し、rerank時に同じ (reading, word) の文脈suffix一致度を `contextAffinity`（suffix共通長2文字以上で発火、4文字で1.0に飽和）として候補に付与する。`AIReranker` は `contextAffinityBonus = min(affinity, 1.0) * 1.50` を加点し、`向き` / `無機` のような同音異義語をユーザー履歴からモデルなしで選べるようにする。また study 候補には `studyFrequency` を渡し、`studyFrequencyBonus = min(0.60, log2(frequency) * 0.10)`（frequency 2以上で発火）でフラットな sourceBias を頻度で補正する。capを0.60とするのは、`更新`（頻度101）と `行進`（頻度11）のような同読みstudy候補ペアで頻度差がMRU順を上書きできるようにするため（0.30では頻度8で飽和し区別できない、BUG-026）。

読み完全一致の判定（`AIReranker.isExactReadingMatch`）はローマ字表記の揺れを含む: `reading == inputPat` に加え、**辞書由来の `kind=exact` かつ reading 非nil** を exact として信頼する。`kind=exact` の付与元である `WordSearch.matchKind` が、`kousinn`（更新の学習reading）と `kousin`（実入力）のようなかな等価readingを exact と判定するため（BUG-026）。外部候補（クリップボード等）も `kind=exact` を持つが reading が nil のため対象外。同じ理由で fast-context の protected exact 判定・同音異義語レビュー対象も `kind=exact` + reading 非nil を信頼し、`kousin` 入力時に `更新`（kousinn）と `行進`（kousin）が同音異義語として比較される。

Swift runtime 側でも `AIReranker.localScoreBreakdown(candidate:request:)` が feature contribution と total score を返す。これにより、offline evaluator の `--show-features` と同じ観点で source bias / kind bias / exact reading bonus / prefix penalty / context bonus / context affinity bonus / study frequency bonus / kanji bonus / natural phrase bonus / punctuation penalty / punctuated input mismatch penalty / incomplete stem penalty / script transition penalty / zenz kanji bonus / raw ASCII penalty をテスト・debug できる。

## Zenz candidate evaluation and constraints

fast-context rerank のモデル経路では、同梱モデルで候補を評価する。azooKey/Zenzai と同じ方針で、candidate evaluation prompt に続く候補 token を1つずつ見て、モデル最尤 token と実候補 token が一致しない場合は `fixRequired(prefixConstraint:)` 相当の prefix を返す。一致している場合は、次点 token の確率比を alternative constraint として保持する。

fast-context rerank の model opt-in 経路では latency と安全性を優先し、Swift heuristic の最上位候補だけを1回 review する。`fixRequiredPrefix` は既存候補に prefix 一致する場合だけ先頭移動に使うが、通常のprefix予測では1文字 prefix を採用しない（`こうほ -> 高品質` や `つか... -> つかっちゃ` のような広すぎる置換を誘発しやすいため）。また現在の最上位候補自身に一致する prefix は順位変更として扱わず、local order を維持する。

読み完全一致の `.exact` / `.compound` 最上位候補は、原則として model review で prefix 予測候補へ沈めない。ただし、左文脈があり、同じ読みの `.exact` / `.compound` 候補が複数ある場合（例: `muki` の `向き` / `無機`、`kinou` の `機能` / `昨日`）は exact 同音異義語レビューとして扱う（ADR-021）。この場合は `fixRequiredPrefix` 経由の置換ではなく、`exactHomophoneCandidateIndices` が返す protected exact 候補（既定上位3件、`aiRerankExactHomophoneMaxCandidates` で最大6）を `LlamaZenzContext.score` の条件付き平均logprobで**直接比較**する。未完成語幹（候補集合内に `語幹+い` または `っ` 終わり語幹の完成形が存在する候補、例: `ください` があるときの `くださ`）は比較対象から除外するため、モデルが未完成候補を昇格させることは構造上できない。また、**入力の生かな表記**（候補textが `request.hiragana` と一致するひらがなのみ候補）は、bestでない限り比較対象から除外する。文字レベルLMはかな列に系統的に高い確率を与えるため、`こみ` が `込み` に、`いっか` が `一家` に文脈と無関係に勝ってしまう（BUG-024）。生かな表記は heuristic 順・かな確定キー（`;` / `q`）から常に到達できるので失うものはなく、`ください`（入力 `kudasa` の生かな表記は `くださ`）のような正当なひらがな語は比較対象に残る。bestが生かな表記そのものの場合は除外せず、漢字同音異義語を上へ昇格できる。対称に、**記号のみの候補**（かな・漢字を1文字も含まないtext、例: `〇` `△` `×`）は比較対象から**無条件に**除外する。文字レベルLMは記号に系統的に低い確率を与えるため（`まる` の `〇`=-8.60 vs `円`=-2.91）、ユーザーが繰り返し選んだ記号でも毎回漢字同音異義語に上書きされてしまう（BUG-031）。bestが記号の場合は比較自体がスキップされ、記号がchallengerとして昇格することもない。`〇円` のようにかな・漢字を含む混在テキストは比較に残る。勝者が現在のbestを margin（`aiRerankExactHomophoneMargin`、既定0.10）**+ bestのcontextAffinity優位 × 2.0 + bestのstudy頻度優位 × 2.0**（logprob単位）以上上回った場合のみ先頭を入れ替える。頻度優位は `log2(best頻度 / 挑戦者頻度)`（挑戦者がstudy語でなければ頻度1扱い、負なら0）で、`selectExactHomophoneWinner(studyFrequencies:frequencyMarginWeight:)` が計算する（BUG-036: dogfood 2026-09-11 で `君`(31) を `キミ`(7) に、`指摘`(63) を `私的`(3) に上書きし、いずれもユーザーが戻していた。確定直前の結果別top1率は上書きあり 88.5% vs 上書きなし 98%）。ユーザーが部分一致文脈（affinity < skip閾値0.75）で学習済みの選好を、モデルが僅差で覆すことを防ぐ（dogfood 2026-07-14: 学習済み `仕様` をモデルが `使用` へ再降格していた）。ログ outcome は `exact-homophone-fixed`（入れ替え）/ `exact-homophone-kept-local`（勝者が別候補だがmargin不足）/ `exact-homophone-passed`（bestが勝者）/ `exact-homophone-unavailable`（scoring失敗）を使う。

bestの `contextAffinity` が閾値（`aiRerankExactHomophoneAffinityThreshold`、既定0.75 = suffix一致3文字以上）以上の場合、同音異義語レビュー自体をスキップする（outcome `affinity-skip`）。ユーザーがその文脈で既に選んだ同音異義語をモデルが覆すべきではなく、レビューのレイテンシも節約できる。

通常review（非同音異義語）は入力長ゲートを別に持つ（`aiRerankFastContextNormalReviewMinInputLength`、既定5、1〜12）。dogfood計測（2026-07-08、18時間）で通常reviewは入力長4だと81回中fix 0回（純粋な無駄撃ち）であり、観測されたfix価値はすべて入力長5以上だった。一方、同音異義語reviewは入力長4がfix率30%の主戦場（`muki` / `tosi` 等の2かな読み）のため、グローバルゲート（`aiRerankFastContextModelMinInputLength`、既定4）のままとする。ゲートで弾いた場合の outcome は `short-input-skip`。

通常review経路の `fixRequiredPrefix` が1文字の場合、`hasPrefix` 一致は広すぎるため従来は常に `kept-local` の no-op だった（dogfood 2026-07-05 で通常reviewの約48%が `書` / `十` のような1文字漢字prefixで空振り）。現在は「候補textがprefixと完全一致し、かつ読み完全一致（protected exact）」の候補に限って昇格を許可する。

`LlamaZenzContext` は `score` と `evaluateCandidate` の成功結果を FIFO 256件でメモ化する。モデルは固定なので結果は不変であり、同一 (context, input) の再レビュー（ウィンドウ再描画・backspace戻り等。dogfoodで1秒以内の同一レビューを複数観測）が即返しになる。失敗（logits確保など一時的要因）はキャッシュしない。

candidate evaluation で モデル最尤 token が EOS の場合（モデルが「ここで文が完結する」と判断したケース）は、failure ではなく pass として扱う。dogfood（2026-07）では `review-unavailable` の437/437件がこの `best-token-is-eos` であり、1回あたり約25msの無駄撃ちと誤った警告ログになっていた。この信号から短縮置換は行わない（未完成語幹昇格の危険があるため）。

## 辞書制約付き生成（ADR-022 → ADR-024 で廃止）

`ConnectionDict.constrainedCompositions` と `ZenzRuntime.selectCandidates` による辞書制約付き選択は、Tab 起動パイプラインの削除（ADR-024）で到達経路を失った。`constrainedCompositions` 自体は `ConnectionDictTests` で仕様を保持している。関連設定と設定画面のトグルは残っているが効果はない。

## Validation

SwiftyGyaim 本体は `order` を必ず検証する。

- 範囲外 index は無視
- 重複 index は無視
- 欠落 index は元順で末尾に追加
- candidateCount が 0 の場合は空配列

これにより、AI が不正な順序を返しても候補を失わない。

## 実行フロー

```text
打鍵（printable）
  -> searchAndShowCands()
       -> WordSearch.search()（prefix）
       -> buildPrefixCandidates(allowModelReview: false)
            raw input → 外部候補（クリップボード/選択テキスト）→ fastContextRerank（heuristic）→ ひらがな
       -> nthCand = 0, showCands()
       -> モデル経路が有効なら scheduleDeferredModelReview()（ADR-026）

aiRerankFastContextReviewDelayMs 後（入力が変わっていなければ）
  -> buildPrefixCandidates(allowModelReview: true)
       -> InProcessAIReranker.rerank(mode=fast-context-rerank)
            protected exact best: 同音異義語レビュー or skip
            それ以外: 最上位候補の evaluateCandidate（入力長 >= 5）
  -> 順序が変わった場合だけ candidates を差し替えて showCands()

Tab / suffix / shortcut while converting
  -> triggerGoogleTransliterate()（google-transliterate.md）
```

## Stale Guard

遅延モデルレビューは `inputGeneration` カウンタと `inputPat` / `searchMode == 0` / `nthCand == 0` の一致を確認してから候補を差し替える。`handle()` の先頭と `resetState()` で保留分を破棄するため、連続打鍵中はモデルが走らない。Google 変換は `pendingGoogleQuery` と `inputPat` の一致で古い応答を破棄する（google-transliterate.md）。

## Legacy: GPT-2 external reranker（未接続）

`Tools/ai-rerank/gyaim-gpt2-char-rerank*.py`（`ku-nlp/gpt2-small-japanese-char` の resident server / client）と、Swift 側の `HTTPAIReranker` / `ExternalCommandAIReranker`（設定キー `aiRerankServerURL` / `aiRerankHTTPTimeoutMs` / `aiRerankCommand` / `aiRerankTimeoutMs`、環境変数 `GYAIM_AI_RERANK_SERVER` / `GYAIM_AI_RERANK_COMMAND`）は 2026-05 の比較実験用で、現在は Swift 本体から呼ばれていない。`Tools/ai-rerank/evaluate-reranker.py` もこの server 向け。削除候補。

## 評価ループ

dogfood中は確定のたびに `Fast context accepted: input=... word=... rank=N candidates=M source=... kind=...` を出力し（`aiRerankFastContextLoggingEnabled=true` 時のみ、prefix mode・意図的確定のみ）、`aggregate-fast-context-log.py` の `acceptedRanks` セクションが rank分布・acceptedTop1Rate / acceptedTop3Rate を集計する。これはユーザーの実入力に対する top1/top3 accuracy の代替指標で、eval fixture のチューニングが実使用と乖離していないかを常時監視する。

CI品質ゲート（issue #57）として、`evaluate-fast-context-rerank.py --gate` を `run-unit-tests.sh` から実行する。`model-required` タグ以外のケースの top1 miss、任意ケースの unsafe top、`model-required` 以外の exact demotion があれば非ゼロ終了し、CIをfailさせる。`model-required` ケース（heuristicでは解けない文脈依存同音異義語）は意図的な伸びしろとしてtop1/demotionチェックから除外する。

dogfoodの週次確認は `python3 Tools/ai-rerank/aggregate-fast-context-log.py --last-minutes 10080` で行い、acceptedRanks（acceptedTop1Rate / rank分布）と byOutcome（fix率・latency p95）を見る。

preference data（M6-1）は `extract-preference-pairs.py` で抽出する。確定時の `Fast context accepted detail:` ログ（`GyaimController.acceptedDetailPayload` が出す単一行JSON。表示上位8件+確定候補の reading / source / kind / studyFrequency / contextAffinity を含む）から、**rank 2以上の確定**（=上に表示されていた候補を飛ばして選んだ強い選好シグナル）を eval fixture と同一スキーマの JSONL に変換する。deactivation確定はaccepted ログ自体が出ないため源流で除外され、rank 1 確定は位置バイアスの弱シグナルとして既定除外（`--min-rank 1` で含められる）。redaction（既定ON）は ASCII識別子・URL・数字列を含むケースを落とす。出力は private語彙を含むため、レビューなしで共有・fixture化しない。

feature weight の学習には `train-fast-context-weights.py` を使う。eval fixture（または同スキーマのpreference JSONL）から `expectedTop` vs 他候補の pairwise logistic regression で feature multiplier を学習し（1.0初期値・1.0方向へL2正則化・非負クランプ）、`--feature-weight` 引数として出力する。`model-required` タグ（heuristic featureでは解けない文脈依存同音異義語）は既定で学習から除外する。

量子化の影響は `Tools/model-training/compare-hf-gguf.py`（M4-1）で計測する。HF非量子化モデルと GGUF Q5_K_M を同じ eval fixture・同じ条件付き平均logprob scoringで比較し、top1一致率・Kendall tau距離を出す（transformers / llama-cpp-python は backend別 opt-in 依存）。

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

- Swift heuristic は文脈 LM ではないため、自然文としての文脈判断はモデル経路に依存する
- 同梱モデルは文字レベル LM のため、かな列に高く・記号に低く確率を与える系統的バイアスがある（BUG-024 / BUG-031 の除外規則で対処）
- 同梱 `gyaim-lm-small-public-v1` は CC-BY-SA-4.0（`Resources/Models/THIRD_PARTY_NOTICES.txt`）
- モデルは起動時に 1 回 mmap するため、差し替えの反映は IME プロセス再起動時

## 将来拡張

- 接続辞書への語頻度付与（connection-only の同音異義語順、例: `omoni` の 主に / 重荷）
- 確定ログ（preference pairs）を使った feature weight / モデルの継続学習
- 遅延レビューの delay 既定値の dogfood 調整

## モデル選択（customModelPath）

同梱zenzと自前モデル（gyaim-lm等）を設定で切り替えられる。

- 設定キー `customModelPath`（settings.json / UserDefaults、GGUF絶対パス。`~`展開可）
- 同梱モデルは **gyaim-lm-small-public-v1**（公開データのみで学習・再配布可、Q5_K_M 70MB）。
  customModelPath が未設定・不在の場合はこの同梱モデルにフォールバックする
- customModelPath は**ドメインデータ入りprivateモデル（gyaim-lm v2以降）用**。
  privateモデルは同梱・コミットしない
- モデルは起動時に1回だけmmapされるため、**反映はIMEプロセスの再起動時**
- ログ・rerank応答の model= ラベルはカスタム時 `custom-<ファイル名>`、同梱時
  `bundled-gyaim-lm-small-public-v1`。dogfoodログでモデル別のA/B集計ができる
- 検証: ModelSelectionTests（選択・フォールバック・ラベル・チルダ展開）
