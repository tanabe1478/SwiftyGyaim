# Spec: キー入力フロー

> Trigger: GyaimController.swift
> Last updated: 2026-07-10 (確定詳細ログの追加 — M6-1)

## 概要

GyaimControllerはIMKInputControllerのサブクラスで、全キー入力の処理を担う。

## 入力状態

| 変数 | 型 | 意味 |
|------|---|------|
| `inputPat` | String | 現在のローマ字入力 |
| `candidates` | [SearchCandidate] | 現在の候補リスト |
| `nthCand` | Int | 選択中の候補インデックス |
| `searchMode` | Int | 0=前方一致, 1=完全一致, 2=Google結果 |
| `converting` | Bool (computed) | `!inputPat.isEmpty` |

## イベント処理の流れ

```
handle(_:client:) → routeEvent() → HandleResult
                         ↓
            handleResultに応じた副作用実行
            ├─ 文字入力 → searchAndShowCands()
            ├─ Space → 候補サイクル or searchMode遷移
            ├─ Enter → fix() で確定
            ├─ ESC → resetState()
            ├─ BS → inputPat末尾削除
            ├─ F6/F7/shortcut → fixAsKana()
            ├─ Tab → AI候補生成 + rerankを明示起動
            └─ Google Transliterate suffix/shortcut → Google候補を取得
```

## routeEvent() の設計意図

`handle(_:client:)` から副作用のない純粋な分岐ロジックを抽出し、`routeEvent()` static methodとして独立させた（ADR-009）。これによりMockIMKTextInputを使わずにユニットテスト可能。

## 確定パス

| パス | メソッド | 学習 | 用途 |
|------|---------|------|------|
| Enter/数字キー | `fix(client:)` | あり | 通常確定（prefix mode の先頭候補が raw `inputPat` の場合のみ Enter は完全一致検索へ遷移）。study と同時に ContextDict へ `(文脈末尾, reading, word)` を記録。`aiRerankFastContextLoggingEnabled=true` かつ prefix mode の意図的確定では `Fast context accepted: ... rank=N` と、preference抽出用の `Fast context accepted detail: ... payload={...}`（表示上位8件+確定候補のメタデータJSON）を出力する |
| F6/`;` | `fixAsKana(hiragana: true)` | あり | ひらがな確定 |
| F7/`q` | `fixAsKana(hiragana: false)` | あり | カタカナ確定 |
| IME切替 | `fix(client:sender, skipStudy: true)` | **なし** | deactivation確定 |
| Shift+X | `deleteCurrentCandidate(client:)` | - | 候補削除（ADR-015） |

## AI rerank

AIによる候補生成は通常入力・候補生成時には自動実行しない。変換中に Tab を押した時だけ `requestAIRerankIfAvailable()` を呼び、ローカル lattice 候補・補完候補を追加する。候補追加後は Swift in-process heuristic / 同梱 Zenz で即 rerank し、server 未起動でも候補順を補正する。Google Input Tools は Tab pipeline では `aiRerankUseGoogle=true` の明示 opt-in 時だけ後追い候補追加に使う（2回目の候補更新が発生するため既定OFF）。GPT-2 server / external command は legacy 比較用で、`aiRerankUseLegacyExternalReranker=true` の明示 opt-in 時だけ後追い rerank する。Shift+Tab による rerank-only は廃止し、変換中は副作用なしで消費する。`` ` `` は既定の Google Transliterate suffix として扱う。

通常入力では、`aiRerankFastContextEnabled=true`（デフォルトON）のとき、生成を伴わない軽量な `fast-context-rerank` だけを同期実行する。対象は prefix mode の辞書候補上位24件（`aiRerankFastContextCandidateLimit` で 2〜48 に調整可能）で、raw input と外部候補（クリップボード/選択テキスト）は順序固定。既定では `AIReranker.localRerank` の Swift heuristic のみを使い、読み完全一致候補を長い予測候補より優先しつつ、直前文脈に強い否定命令 cue（例: `決して`, `禁止`, `してはいけ`）がある場合だけ `従うな` のような予測候補を上げられる。候補には `ContextDict.shared.affinity`（文脈条件付き学習、ADR-020）と study頻度が `contextAffinity` / `studyFrequency` として付与され、同じ文脈で過去に選んだ同音異義語はモデルなしで先頭化できる。`aiRerankUseModelForFastContext=true` の場合だけ in-process model backend を使うが、短い入力では走らせない（`aiRerankFastContextModelMinInputLength`、デフォルト4）。モデル経路では候補ごとの全件scoringではなく、Swift heuristic の最上位候補をZenzで1回だけreviewし、必要な場合だけ既存候補内のprefix一致候補を先頭へ移動する。読み完全一致の `.exact` / `.compound` 最上位候補はモデルで沈めない。ただし、左文脈があり、同じ読みの `.exact` / `.compound` 候補が複数ある場合（例: `muki` の `向き` / `無機`）は exact 同音異義語レビュー（ADR-021）として、protected exact 候補同士（既定上位3件）を条件付き平均logprobで直接比較し、margin（既定0.10）以上勝る候補だけを先頭へ入れ替える。prefix予測候補、`ください` があるときの `くださ` のような未完成語幹、入力の生かな表記に一致するひらがな候補（best以外。BUG-024: 文字LMのかなバイアスで `こみ` が `込み` に勝つ）は比較対象に入らないため、モデルが不正な候補を昇格させることはできない。bestの `contextAffinity` が閾値（既定0.75）以上ならレビュー自体をスキップする（outcome `affinity-skip`）。通常reviewの1文字prefixは、候補textが完全一致する protected exact 候補に限り昇格できる。文脈は末尾だけに制限する（`aiRerankFastContextMaxContextLength`、デフォルト20）。入力ごとの latency・before/after ログは `aiRerankFastContextLoggingEnabled=true` のときだけ出す。通常review（非同音異義語）は追加で入力長5以上を要求する（`aiRerankFastContextNormalReviewMinInputLength`。入力長4はfix実績0のため）。ログには `outcome=heuristic|protected-exact-skip|affinity-skip|short-input-skip|review-fixed|review-passed|review-kept-local|review-unavailable|exact-homophone-fixed|exact-homophone-passed|exact-homophone-kept-local|exact-homophone-unavailable` と `topChanged` を含め、dogfood時にmodel reviewの効果と無駄撃ちを集計できるようにする。

## Google Transliterate

`GoogleTransliterate.triggerSuffix`（デフォルト `` ` ``）を入力末尾に付けるか、設定画面で登録した Google Transliterate shortcut を押すと、現在の読みをひらがな化して Google Input Tools API に送る。API応答後は `searchMode = 2` として Google候補・ひらがな・カタカナを表示する。suffix入力時は `inputPat` からsuffixを取り除いてから検索し、API応答時に `pendingGoogleQuery` と現在の `inputPat` が一致しない古い結果は破棄する。

## IMEライフサイクル

```
activateServer(_:) → 辞書start, クリップボード取得, showWindow
deactivateServer(_:) → hideWindow, fix(skipStudy: true), 辞書finish
```

**重要**: deactivationではsenderをfix()に渡すこと。渡さないとクライアント取得に失敗しテキストが破棄される（Issue #13で修正済み）。

## showCands() のページ送り

`showCands()` は `nthCand + 1` から `maxVisible` 個の候補を `CandidateWindow.updateCandidates()` に渡す。スペースキーで `nthCand` が進むと表示がスクロールする。

ページ情報の計算:
- `hasMore = (nthCand + 1 + maxCandList) < words.count`
- `hasPrev = nthCand > 0`

ひらがなフォールバック: 候補数が `CandidateDisplayMode.current.maxVisible` 未満の場合、ひらがなを候補に追加。

Prefix mode の候補順: `buildPrefixCandidates()` は raw `inputPat` を先頭に保ち、その後に外部候補（クリップボード、選択テキスト）、辞書検索結果、ひらがなフォールバックを並べる。raw `inputPat` を先頭にすることで、短い prefix 入力や完全一致前の入力で `gu` → `具体的`、`maeno` → `前のめり` のような長い prefix 候補が Enter / deactivate で誤確定されるのを防ぐ。一方、候補ウィンドウは `nthCand + 1` 以降を表示するため、コピー後5秒以内のクリップボード候補や選択テキスト候補は表示上の先頭に出る。ただし、URLや `chrome-extension://...` のような URL scheme 形式の文字列、`sns_origination_identity_arn` のような snake_case 風ASCII識別子は外部候補から除外する。また `inputPat` に `?` / `!` / `？` / `！` が含まれる場合は、句読点付き文としての確定を優先し、外部候補を挿入・登録しない。`ha?` のように句読点付きで入力した場合は、fast-context heuristic が句読点を含まない長い local/study 候補を抑制し、`は？` のような句読点付き候補を守る。

## 既知の制約

- `handle(_:client:)` のclientはIMKTextInputだが、ターミナルアプリではCtrl+keyを横取りされる
- `routeEvent()` はstaticだがGyaimControllerのインスタンス状態に依存する引数を受け取る
