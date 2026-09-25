# Spec: AI Rerank

> Trigger: AIReranker.swift, ZenzRuntime.swift, ZenzRuntime+Scoring.swift, InProcessAIReranker.swift, AIRerankBackend.swift, GyaimController+FastContextRerank.swift, FastContextTrace.swift
> Last updated: 2026-09-26 (同音異義語の採点を scoreBatch で一括化)

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
- `aiRerankFastContextReviewDelayMs`（既定 0、レビュー開始前のスロットル）/ `aiRerankFastContextSelectionWaitMs`（既定 30、Space での合流待ち。ADR-029）
- `aiRerankExactHomophoneMargin` / `aiRerankExactHomophoneMaxCandidates` / `aiRerankExactHomophoneAffinityThreshold` / `aiRerankExactHomophoneFrequencyMarginWeight`
- `aiRerankZenzWeight` / `aiRerankZenzMaxCandidates`（全件 rerank 用）
- `customModelPath`（モデル差し替え）


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

文脈条件付き学習（ADR-020）として、確定時に `(左文脈末尾8文字, reading, word)` を `~/.gyaim/contextdict.txt` に記録し、rerank時に同じ (reading, word) の文脈suffix一致度を `contextAffinity`（suffix共通長2文字以上で発火、4文字で1.0に飽和）として候補に付与する。`AIReranker` は `contextAffinityBonus = min(affinity, 1.0) * 1.50` を加点し、`向き` / `無機` のような同音異義語をユーザー履歴からモデルなしで選べるようにする。また study 候補には `studyFrequency` を渡し、`studyFrequencyBonus = min(0.60, log2(frequency) * 0.10)`（frequency 2以上で発火）でフラットな sourceBias を頻度で補正する（一般コーパスの出現頻度による `corpusFrequencyBonus` は実験用で既定無効。`aiRerankCorpusFrequencyPath` / `aiRerankCorpusFrequencyWeight`、Python evaluator には未移植）。capを0.60とするのは、`更新`（頻度101）と `行進`（頻度11）のような同読みstudy候補ペアで頻度差がMRU順を上書きできるようにするため（0.30では頻度8で飽和し区別できない、BUG-026）。

読み完全一致の判定（`AIReranker.isExactReadingMatch`）はローマ字表記の揺れを含む: `reading == inputPat` に加え、**辞書由来の `kind=exact` かつ reading 非nil** を exact として信頼する。`kind=exact` の付与元である `WordSearch.matchKind` が、`kousinn`（更新の学習reading）と `kousin`（実入力）のようなかな等価readingを exact と判定するため（BUG-026）。外部候補（クリップボード等）も `kind=exact` を持つが reading が nil のため対象外。同じ理由で fast-context の protected exact 判定・同音異義語レビュー対象も `kind=exact` + reading 非nil を信頼し、`kousin` 入力時に `更新`（kousinn）と `行進`（kousin）が同音異義語として比較される。

Swift runtime 側でも `AIReranker.localScoreBreakdown(candidate:request:)` が feature contribution と total score を返す。これにより、offline evaluator の `--show-features` と同じ観点で source bias / kind bias / exact reading bonus / prefix penalty / context bonus / context affinity bonus / study frequency bonus / kanji bonus / natural phrase bonus / punctuation penalty / punctuated input mismatch penalty / incomplete stem penalty / script transition penalty / zenz kanji bonus / raw ASCII penalty をテスト・debug できる。

## Zenz candidate evaluation and constraints

fast-context rerank のモデル経路では、同梱モデルで候補を評価する。azooKey/Zenzai と同じ方針で、candidate evaluation prompt に続く候補 token を1つずつ見て、モデル最尤 token と実候補 token が一致しない場合は `fixRequired(prefixConstraint:)` 相当の prefix を返す。一致している場合は、次点 token の確率比を alternative constraint として保持する。

fast-context rerank の model opt-in 経路では latency と安全性を優先し、Swift heuristic の最上位候補だけを1回 review する。`fixRequiredPrefix` は既存候補に prefix 一致する場合だけ先頭移動に使うが、通常のprefix予測では1文字 prefix を採用しない（`こうほ -> 高品質` や `つか... -> つかっちゃ` のような広すぎる置換を誘発しやすいため）。また現在の最上位候補自身に一致する prefix は順位変更として扱わず、local order を維持する。

読み完全一致の `.exact` / `.compound` 最上位候補は、原則として model review で prefix 予測候補へ沈めない。ただし、左文脈があり、同じ読みの `.exact` / `.compound` 候補が複数ある場合（例: `muki` の `向き` / `無機`、`kinou` の `機能` / `昨日`）は exact 同音異義語レビューとして扱う（ADR-021）。この場合は `fixRequiredPrefix` 経由の置換ではなく、`exactHomophoneCandidateIndices` が返す protected exact 候補（既定上位6件、`aiRerankExactHomophoneMaxCandidates` で1〜6。ADR-031 で3件から変更）を `LlamaZenzContext.scoreBatch`（1回の `llama_decode` で全候補を採点。値は `score` と同じ）の条件付き平均logprobで**直接比較**する。未完成語幹（候補集合内に `語幹+い` または `っ` 終わり語幹の完成形が存在する候補、例: `ください` があるときの `くださ`。`い` / `た` / `だ` で終わる語は `+い` があっても完成語とみなす: BUG-025, BUG-043）は比較対象から除外するため、モデルが未完成候補を昇格させることは構造上できない。また、**入力の生かな表記**（候補textが `request.hiragana` と一致するひらがなのみ候補）は、bestでない限り比較対象から除外する。文字レベルLMはかな列に系統的に高い確率を与えるため、`こみ` が `込み` に、`いっか` が `一家` に文脈と無関係に勝ってしまう（BUG-024）。生かな表記は heuristic 順・かな確定キー（`;` / `q`）から常に到達できるので失うものはなく、`ください`（入力 `kudasa` の生かな表記は `くださ`）のような正当なひらがな語は比較対象に残る。bestが生かな表記そのものの場合は除外せず、漢字同音異義語を上へ昇格できる。対称に、**記号のみの候補**（かな・漢字を1文字も含まないtext、例: `〇` `△` `×`）は比較対象から**無条件に**除外する。文字レベルLMは記号に系統的に低い確率を与えるため（`まる` の `〇`=-8.60 vs `円`=-2.91）、ユーザーが繰り返し選んだ記号でも毎回漢字同音異義語に上書きされてしまう（BUG-031）。bestが記号の場合は比較自体がスキップされ、記号がchallengerとして昇格することもない。`〇円` のようにかな・漢字を含む混在テキストは比較に残る。勝者が現在のbestを margin（`aiRerankExactHomophoneMargin`、既定0.10）**+ bestのcontextAffinity優位 × 2.0 + bestのstudy頻度優位 × 2.0**（logprob単位）以上上回った場合のみ先頭を入れ替える。頻度優位は `log2(best頻度 / 挑戦者頻度)`（挑戦者がstudy語でなければ頻度1扱い、負なら0）で、`selectExactHomophoneWinner(studyFrequencies:frequencyMarginWeight:)` が計算する（BUG-036: dogfood 2026-09-11 で `君`(31) を `キミ`(7) に、`指摘`(63) を `私的`(3) に上書きし、いずれもユーザーが戻していた。確定直前の結果別top1率は上書きあり 88.5% vs 上書きなし 98%）。ユーザーが部分一致文脈（affinity < skip閾値0.75）で学習済みの選好を、モデルが僅差で覆すことを防ぐ（dogfood 2026-07-14: 学習済み `仕様` をモデルが `使用` へ再降格していた）。ログ outcome は `exact-homophone-fixed`（入れ替え）/ `exact-homophone-kept-local`（勝者が別候補だがmargin不足）/ `exact-homophone-passed`（bestが勝者）/ `exact-homophone-unavailable`（scoring失敗）を使う。

**採点済みの2位以下への反映（ADR-028）**: 先頭の判定後、先頭以外の採点済み同音候補のスロット同士だけをモデルスコア降順で入れ替える。先頭の頻度/affinity/marginガード、採点上限（既定6件、ADR-031）、フィルタは変更しない。未採点・採点失敗・除外候補の位置はこの追加操作では固定し、同点は元順を維持する。先頭の採点失敗または有効スコア2件未満では全順を維持する。既存先頭判定が `fixed` の場合は同outcomeを維持し、先頭を変えず下位だけ変えた場合は `exact-homophone-tail-reranked` とする。`AIRerankResponse.review.topDecision` には元の先頭判定（`fixed` / `passed` / `kept-local` / `unavailable`）を保持する。スコアの追加計算はない。生スコア最大の挑戦者がガードを通らないとき次点の先頭昇格を試す変更や、頻度重みの調整は今回含めない。

bestの `contextAffinity` が閾値（`aiRerankExactHomophoneAffinityThreshold`、既定0.75 = suffix一致3文字以上）以上の場合、同音異義語レビュー自体をスキップする（outcome `affinity-skip`）。ユーザーがその文脈で既に選んだ同音異義語をモデルが覆すべきではなく、レビューのレイテンシも節約できる。

通常review（非同音異義語）は入力長ゲートを別に持つ（`aiRerankFastContextNormalReviewMinInputLength`、既定5、1〜12）。dogfood計測（2026-07-08、18時間）で通常reviewは入力長4だと81回中fix 0回（純粋な無駄撃ち）であり、観測されたfix価値はすべて入力長5以上だった。一方、同音異義語reviewは入力長4がfix率30%の主戦場（`muki` / `tosi` 等の2かな読み）のため、グローバルゲート（`aiRerankFastContextModelMinInputLength`）に従う。グローバルゲートは ADR-031 で既定4→3に下げた（`kai` の 会/回、`hou` の 方/法 など3文字の同音異義語を文脈で選ぶため）。ゲートで弾いた場合の outcome は `short-input-skip`。

通常review経路の `fixRequiredPrefix` が1文字の場合、`hasPrefix` 一致は広すぎるため従来は常に `kept-local` の no-op だった（dogfood 2026-07-05 で通常reviewの約48%が `書` / `十` のような1文字漢字prefixで空振り）。現在は「候補textがprefixと完全一致し、かつ読み完全一致（protected exact）」の候補に限って昇格を許可する。

`LlamaZenzContext` は `score` と `evaluateCandidate` の成功結果を FIFO 256件でメモ化する。モデルは固定なので結果は不変であり、同一 (context, input) の再レビュー（ウィンドウ再描画・backspace戻り等。dogfoodで1秒以内の同一レビューを複数観測）が即返しになる。失敗（logits確保など一時的要因）はキャッシュしない。

candidate evaluation で モデル最尤 token が EOS の場合（モデルが「ここで文が完結する」と判断したケース）は、failure ではなく pass として扱う。dogfood（2026-07）では `review-unavailable` の437/437件がこの `best-token-is-eos` であり、1回あたり約25msの無駄撃ちと誤った警告ログになっていた。この信号から短縮置換は行わない（未完成語幹昇格の危険があるため）。

## 辞書制約付き生成（ADR-022 → ADR-024 で廃止）

Tab 起動パイプラインの削除（ADR-024）で到達経路を失った `ZenzRuntime` の生成・選択メソッド、`AICandidateGenerationBackend`、`WordSearch.connectionCompositions`、設定画面の「辞書制約付き生成」トグルと関連キーは削除済み。`ConnectionDict.constrainedCompositions` だけは `ConnectionDictTests` で仕様を保持している（将来の再利用候補）。

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
       -> モデル経路が有効なら startAsyncModelReview()（ADR-029、背景 queue）

背景 queue（最新の入力だけ。cancelled な ticket はモデルを呼ばない）
  -> buildPrefixCandidates(allowModelReview: true)
       -> InProcessAIReranker.rerank(mode=fast-context-rerank)
            protected exact best: 同音異義語レビュー or skip
            それ以外: 最上位候補の evaluateCandidate（入力長 >= 5）
  -> ticket に結果を格納 → main.async applyReview()
       -> 世代・入力・nthCand == 0 が不変なら candidates を差し替えて showCands()

Space（nthCand == 0）while review in flight
  -> joinInFlightReviewBeforeSelection(): 最大 aiRerankFastContextSelectionWaitMs 待って applyReview()

Tab / suffix / shortcut while converting
  -> triggerGoogleTransliterate()（google-transliterate.md）
```

## Stale Guard

遅延モデルレビューは `inputGeneration` カウンタと `inputPat` / `searchMode == 0` / `nthCand == 0` の一致を確認してから候補を差し替える。`handle()` の先頭と `resetState()` で保留分を破棄するため、連続打鍵中はモデルが走らない。Google 変換は `pendingGoogleQuery` と `inputPat` の一致で古い応答を破棄する（google-transliterate.md）。

## Legacy: GPT-2 external reranker（削除済み）

2026-05 の比較実験に使った `ku-nlp/gpt2-small-japanese-char` の resident server / client（`Tools/ai-rerank/gyaim-gpt2-char-rerank*.py`、`evaluate-reranker.py`、`requirements.txt`）と Swift 側の `HTTPAIReranker` / `ExternalCommandAIReranker` は、呼び出し元がないため削除した。当時の測定値は git 履歴（#48 以前）を参照。

## 評価ループ

dogfood中は確定のたびに `Fast context accepted: input=... word=... rank=N candidates=M source=... kind=...` を出力し（`aiRerankFastContextLoggingEnabled=true` 時のみ、prefix mode・意図的確定のみ）、`aggregate-fast-context-log.py` の `acceptedRanks` セクションが rank分布・acceptedTop1Rate / acceptedTop3Rate を集計する。これはユーザーの実入力に対する top1/top3 accuracy の代替指標で、eval fixture のチューニングが実使用と乖離していないかを常時監視する。

CI品質ゲート（issue #57）として、`evaluate-fast-context-rerank.py --gate` を `run-unit-tests.sh` から実行する。`model-required` タグ以外のケースの top1 miss、任意ケースの unsafe top、`model-required` 以外の exact demotion があれば非ゼロ終了し、CIをfailさせる。`model-required` ケース（heuristicでは解けない文脈依存同音異義語）は意図的な伸びしろとしてtop1/demotionチェックから除外する。

dogfoodの週次確認は `python3 Tools/ai-rerank/aggregate-fast-context-log.py --last-minutes 10080` で行い、commitOutcomes（firstCandidateRate / strict・suspectedMissRate）を主指標として見る。acceptedRanks と byOutcome（fix率・latency p95）は補助。

acceptedRanks は prefix mode の意図的確定だけを分母にするため、候補が悪いときにユーザーが取る逃げ道（Enter で完全一致モード、かな確定、Google 変換）が分母から消え、失敗ほど見えない。2026-09-13〜24 の実ログで acceptedTop1Rate 0.975 に対し、全確定経路の firstCandidateRate は 0.816 だった（「見た」が「見たい」の書きかけ判定で23位に落ち、完全一致モードへ逃げた例など）。

### 確定経路別の集計（commitOutcomes / commitDiagnostics）

`commitOutcomes` は既存のログ行（`search(..., prefix|exact)`・`Fixed:`・`Fixed as kana`・`Google Transliterate triggered`・`Study skipped (deactivation)`・rerank 行の `after`）から全確定を再構成するので旧ログにも使える。確定語を同じ入力の直前 rerank の辞書先頭8件と照合し、次に分類する。

| 分類 | 意味 |
|---|---|
| `prefix-top1` / `kana-top1` | 辞書1位がそのまま欲しい語だった（hit） |
| `exact-top1` / `google-top1` | 予測で1位だった語を、Enter で完全一致モードへ移ってから / Google 変換で確定した（hit。操作の癖で、順位の失敗ではない） |
| `prefix-lower` / `exact-escape` / `google` | 1位ではなかった（strict miss） |
| `kana-other` / `kana-absent` | かな確定した語が辞書1位と異なり、同じ読みを集計期間中に漢字でも確定している（suspected miss） |
| `kana-intended` | かな確定した語が辞書1位と異なるが、その読みを漢字で確定したことがない（助詞を毎回かなキーで確定するなど。判定対象外） |
| `prefix-raw` / `kana-no-dictionary` / `deactivation` | 判定対象外 |

`firstCandidateRate = hit / (hit + strict + suspected)`。`strictMissRate` はかな確定をすべて意図的とみなした下限、`suspectedMissRate` は上限。commit 行に controller がないため、別フィールドの入力が交互に来ると照合が混ざり得る。

`commitDiagnostics` は `Commit outcome: input=... payload={...}` 行（全確定経路で1行、`aiRerankFastContextLoggingEnabled=true` 時のみ）を読み、上と同じ規則（予測1位の exact/google は miss にしない、漢字で確定したことのない読みのかな確定は `kanaIntended` として数える）で miss を prefix list 上の順位（`byPrefixRank`）・モデル採点集合への包含（`byScoredSet`: scored / notScored / noReview）・`modelOutcome` 別に数える。`notScored` の miss はモデルの質にかかわらず救えないので、採点集合・heuristic 側の問題として扱う。

payload: `path`（prefix / exact / google / kana-hiragana / kana-katakana / deactivation）、`context`（モデルに渡すのと同じ末尾20文字）、`prefixCandidateCount`、`prefixRank`（直前の prefix list 上の順位。raw=0、先頭表示=1、なければ省略）、trace がある場合は `controller` / `composition` / `generation` / `modelState` / `heuristicRank` / `proposedRank`、レビュー結果がある場合は `modelOutcome` / `inDictionarySnapshot`（レビュー request の辞書候補に含まれたか）/ `scoredCount` / `inScoredSet`。完全一致モードや Google へ移るときは、直前の prefix trace と候補語リストを `escapedPrefixTrace` / `escapedPrefixWords` に退避し、確定時に使う。確定語以外の候補文字列は記録しない。

### タイピングシミュレーション（ログなしの評価）

`Tools/eval/run-typing-simulation.sh` は、正解付きの区切り列（`Tools/eval/typing-corpus.jsonl`、`build-typing-corpus.py` で生成）を `TypingSimulationTests` で本物の検索・`buildPrefixCandidates`（heuristic とモデルレビュー）に流し、区切りごとに正解の順位を記録する。ひらがなのみの区切りはかな確定、カタカナのみはカタカナ確定、それ以外は変換として扱い、確定後は `GyaimController` と同じく study / ContextDict を更新して次へ進む。予測リストにない語は完全一致モード、それにもなければ `absent` とし、Google 変換で得たとみなして学習する。

各文は「普段の区切り」（dogfoodログで観測した、内容語ごとに変換し助詞はかな確定する打ち方）と「自然な区切り」（複合語・動詞+助動詞・名詞+する をまとめる）の2通りを持つ。両者の差は、ユーザーが癖で回避している弱点の大きさを示す。

辞書・ContextDict・settings はすべて一時ディレクトリに置き、`loggingEnabled=false` で `~/.gyaim/gyaim.log` に書かない。`GYAIM_TYPING_SIM=1` のときだけ実行され、通常のユニットテストではスキップされる。`GYAIM_TYPING_SIM_EPOCHS` で複数回流して学習後の状態を、`GYAIM_TYPING_SIM_STUDYDICT` で既存の学習辞書の写しから始めた状態を測れる。`GYAIM_TYPING_SIM_SETTINGS`（JSONオブジェクト）で設定キーを上書きして条件を比べられる（ADR-031 の採点件数・入力長の比較に使用）。

指標は1位率（`firstCandidateRate`、モデルあり / `heuristicFirstCandidateRate`）に加えて、確定までの操作回数 `ops` / `opsPerSentence` を出す。ローマ字の打鍵は含めず、予測 r 位は Space×r+確定、完全一致モードは Enter+Space×位置+確定、候補なしは Google 変換の1位で確定する仮定の3回、かな確定・数字等の raw 確定は1回と数える。区切りをまとめると確定回数が減るため、1位率だけでは測れない「長い単位で打てるようになった」効果を比べられる。

heuristic を減らす検討用に、`GYAIM_TYPING_SIM_LLM_RANK=1` で `TypingSimulationLLMRanker` が辞書候補（最大24件）を同梱モデルだけで採点し、`llmRank`（平均logprobのみ）・`llmStudyRank@w`（+ w × log2(1+学習頻度)）・`llmStudyContextRank@c`（+ c × ContextDict affinity）を記録する。`GYAIM_TYPING_SIM_TRAIN_CORPUS` を指定すると、そのコーパスを学習だけのために先に流してから評価コーパスを測る。`typing-corpus-heldout.jsonl` は `typing-corpus.jsonl` と同じ語を別の文脈で使った評価専用の20文で、同じ文の繰り返しによる ContextDict の丸暗記を避けて学習の持ち越しを測る。2026-09-26 時点（held-out、普段の区切り75件）では、学習後に今の方式 0.893、LLM + 学習頻度 + 文脈学習 0.880、heuristic のみ 0.813。全件採点の遅延が製品化の前提課題だったが、`scoreBatch` で解消の見込み（下記）。

### 採点の一括化（scoreBatch）

`LlamaZenzContext.score` は候補ごとに `llama_decode` を呼ぶ。プロンプト部分は KV キャッシュを共通接頭辞で使い回すが、decode 1回ごとに数 ms の固定コストがかかる（Release、24候補で約65ms）。`LlamaZenzContext+Batch.swift` の `scoreBatch(prompt:continuations:)` は、プロンプトを1回だけ decode してその最後の位置の log-softmax で全候補の1トークン目を採点し、2トークン目以降は候補ごとに別の sequence（プロンプトの KV セルを `llama_kv_cache_seq_cp` で共有）として1つの batch にまとめて decode する。Release で6候補 約20→8ms、24候補 約65→11ms（`LlamaScoringBenchmarkTests`、`GYAIM_LLAMA_BENCH=1`）。値は `score` と Metal で 2e-3 以内、CPU バックエンド（CI）で 0.08 程度まで一致する（batch サイズでカーネルの丸めが変わるため。`testBatchScoresMatchOneByOneScores` は 0.1 で検査）。候補数が48を超える、またはトークン数が batch 容量（512）を超える場合は `score` に戻る。同音異義語レビュー（`exactHomophoneReviewRerank`）はこれを使う。コーパスは手書きの推定区切りなので、得られるのは実機の順位ではなく比較用の目安。

### モデル効果の評価（composition trace）

「モデルが何回変更したか」ではなく「同じ確定について heuristic 単独の順位より良くなった件数 − 悪くなった件数」で効果を測る。`GyaimController` は composition ごとに `FastContextTrace` を保持し、確定時の `Fast context accepted detail` payload に次を載せる。

- `traceVersion=2` / `controller`: controllerインスタンスごとのUUID。プロセス再起動・別アプリのcontroller間でIDを衝突させない
- `composition`: 新しい入力を始めるたびに増える ID。`controller=UUID composition=N gen=M pass=prereview|review|sync|heuristic` がrerank行にも付く
- `generation`: リクエストの世代。検索開始前に割り当て、レビュー予約では進めない。確定キーでstale guardの世代が進んでもtraceは元リクエストの世代を保持する
- `modelState`: `not-scheduled`（rerank/model/backend無効・入力長不足）/ `pending` / `cancelled` / `applied-changed` / `applied-unchanged` / `skipped`（保護ゲート・候補不足・backend fallback等で採点なし）/ `unavailable`（採点を試みたが利用不能）。既存の `sync` は旧ログ互換のみ
- `deferred`: 遅延レビューか。delay=0でもまずheuristic単独リストを作るため、同期実行も同じ改善/悪化指標で比較できる
- `heuristicRank` / `proposedRank` / `chosenRank`: 確定語のheuristic単独順・レビュー提案順・実際に候補配列へ適用された順における順位。raw=0、最初の表示候補=1。先頭32件より下位の確定でもrankは完全なリストから計算する
- `heuristicOrderHead` / `proposedOrderHead` / `displayedOrderHead`: 各順の先頭32件を、heuristicリスト内の位置で表した配列（未知なら-1）。raw/外部候補の文字列を追加で記録しない
- `dictionaryCandidates` / `dictionaryHeuristicOrder` / `dictionaryProposedOrder`: レビュー時のrequest候補metadata（通常上位24件、設定最大48）とrequest index順。表示全体のindexとは区別する
- `model` / `modelOutcome` / `modelContext`: レビュー応答のモデル・結果・実際に渡した文脈
- `review`: 実際のモデル評価がある場合のみ付く。`candidateIndices`（採点を試みた集合）、`scores`（成功した有限な平均logprobのみ）、`scoreOrder`（生スコア降順、同点はindex順）、`topDecision`（先頭判定）。通常prefixレビューは候補評価でありlogprob比較ではないためscores/scoreOrderは空

確定detailは、clientを解決してinsertText等を呼んだ後、study/ContextDict更新の前に記録する。deactivation・かな専用確定・Google変換は従来どおり対象外（これらは `Commit outcome` 行で数える）。Esc/リセットや次の検索では古いtraceを破棄する。スキップを「モデルが承認した」と数えない。

`aggregate-fast-context-log.py` の `modelEffect.rankEffect` は、同じ確定選択について `heuristicRank - chosenRank` をrank改善量とし、改善/悪化/不変件数、`netImproved`、`rankGainSum`、`meanRankGain` を返す。`byOutcome` で下位のみ変更の効果も分離できる。`appliedChanged` は変更ありケースだけの互換集計。raw確定・非整数/負のrank・提案順位と適用順位の不整合は品質比較から除外し、v2の同一(controller, composition, generation)は重複排除する。

`committedBeforeReviewRate` は、**意図的確定まで残った遅延対象リクエスト**のうちpending/cancelledだった割合。入力途中で消えたリクエストや同期実行を分母に混ぜない（`deferredCommitCount`を併記）。全打鍵に対するキャンセル率ではない。確定は位置バイアスを持つ観測ラベルであり、因果的accuracyとは呼ばない。以後の頻度係数の変更は、これらの指標と既知の誤上書き例を含む時系列holdoutで判断する。

ログは既存の `aiRerankFastContextLoggingEnabled` によるopt-inのみ。追加snapshotにはprivate語彙が含まれるため無断で共有/学習に使わない。文脈の取得源・長さは変更しない。`topChanged` は辞書before/afterの**先頭だけ**を比較するよう訂正した。集計・レビュー抽出ツールも新旧タグ付き/タグなしログを読み、旧topChanged（上位8件比較）を信じずbefore/afterの先頭から再計算する。

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
