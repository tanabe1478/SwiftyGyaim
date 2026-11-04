# Issue #125: 実運用の文脈で学習する

Last updated: 2026-11-04

## 結果と残作業

既存データと公開データで学習・評価を実施した。追加のMac選択ログは要求しない。
候補Vは公開baseを初期値に再学習し、固定評価の文脈5/10/20文字すべてで改善した。
ただし公開評価は増減が混在する。Mac native比較が完了し、20文字の本番式は11件退行したためVは採用見送り。
全件p50/p95は11.26/15.65msで速度ゲートは満たす。モデルはprivate HFに保管し、アプリへ適用していない。
全学習・評価プロセスは終了している。
候補学習の読み正規化も統一した（BUG-046）。Vの全11,865行は既に正規化済みで、
この修正後もtrain/validation件数と教師cacheの全ペア対応が変わらないことを確認した。

固定11,072件のHF FP32モデル単体評価:

| 文脈長 | 公開base正解 | V正解 | 差 | 良化 / 悪化 |
|---|---:|---:|---:|---:|
| 0 | 8,589 | 8,861 | +272 | 313 / 41 |
| 5 | 9,618 | 9,646 | +28 | 68 / 40 |
| 10 | 9,600 | 9,631 | +31 | 64 / 33 |
| 20 | 9,778 | 9,817 | +39 | 60 / 21 |

追加評価の公開baseとの差:

| 評価 | 0文字 | 5文字 | 10文字 | 20文字 |
|---|---:|---:|---:|---:|
| 固定gap>=30秒・4,140件・HF FP32 | +106 | -3 | -1 | +7 |
| 公開UD97件・Q5 | +1 | -2 | -1 | 0 |
| 公開Tatoeba325件・Q5 | -1 | -1 | +1 | 0 |

Tatoebaの事前レビュー202件の20文字評価は両モデル200件正解で同数。
公開UD97は補助診断であり、各長さで必ず改善することをIssueの必須条件とはしない。
一方、固定評価を反復して選択した結果は独立した汎化確認ではない。
reading-cluster bootstrapの95%区間（差のpercentage points）は5/10/20文字で
[-0.0571,0.5738] / [0.0611,0.5176] / [0.1634,0.5601]。
これは過去の実験選択や時系列依存を補正せず、一般的な優位性の証明ではない。

Mac報告では全件の本番式は文脈0/5/10/20で+9/+1/+5/-11、gap30では+3/+1/+3/-1。
モデル単体の改善が本番式にどう反映されたか、ケース別traceで原因を調べる段階。
ユーザーの現時点の許可範囲は分析器・設計までで、追加学習とモデル適用は行わない。
[NATIVE-ANALYSIS.md](NATIVE-ANALYSIS.md)に分析器の使い方と次の学習設計をまとめた。
Mac報告: https://github.com/tanabe1478/SwiftyGyaim/issues/125#issuecomment-6629234575
参照: https://github.com/tanabe1478/SwiftyGyaim/issues/125#issuecomment-6604482373

## データから分かったこと

既存domainデータの文脈変種を行単位で分けると同じ読み・正解がtrain/validationに混入する。
このためSFTは正規化した（読み, 正解）単位、候補学習は読み単位で分割する。
固定評価の補正後truthと補正前chosenを全ての文脈から除外し、候補学習では
chosen/rejected双方に同じ除外を適用する。従来holdoutも除外する。
これは保守的な隔離であり、イベントIDがないdomainデータの時系列隔離を保証するものではない。

公開文の表記を正例、同読み・同接続クラスの辞書候補を負例として使えるが、
別の候補も文脈上正しいことがある。辞書候補はユーザーの実際の拒否を意味しない。
特に長文脈の正解を5/10文字に短縮すると、判断材料が失われたり正解が変わったりする。
したがって「テストデータが悪い」と断定せず、学習信号の曖昧さと評価条件の差を分けて扱う。
固定テストを好成績になるように修正してはいない。

候補Vでは学習側のみ、教師が20文字ではmargin>=1、短縮5/10文字ではmargin<=0となる
248件（5文字185件、10文字63件）を除外した。教師スコア自体は変更せず、
validationの内容と順序も保持した。短文脈で判断が変わることは誤ラベルの証明ではなく、
この選別は教師判断の一貫性を調べる実験である。

## 追加したツール

| ファイル | 用途 |
|---|---|
| `prepare_context_training.py` | 固定評価除外・文脈変種の分割・SFT用manifest |
| `build_context_contrasts.py` | 公開文と辞書から同読みの対比ペアを作成 |
| `train_context_preference.py` | pair / context_gain / context_distill学習 |
| `context_distillation.py` | 教師cache検証と文脈候補蒸留loss |
| `cache_context_teacher.py` | 教師の文脈ありmarginをFP32でキャッシュ |
| `evaluate_context_cases.py` | 文脈長別のHF評価、またはnativeケース別exportの集計 |
| `compare_context_runs.py` | 同一条件での正解数差・良化/悪化集計 |

データ出力はgitignoreされた`data/`、モデル・評価出力は`runs/`の新規パスに限定する。
元ファイル・ケース・教師重み・cacheのhash、設定、splitの件数を記録する。
HF評価の既定`hf`とSwiftの空白/LF処理を反映する`native-whitespace`を明示的に区別し、
backend・precision・前処理が異なる結果の比較を拒否する（BUG-045）。
どちらもHF-proxyで、native本番式や速度の代替ではない。
Pythonの文脈長はUnicode code point単位で、Swiftのgrapheme単位とは一部文字で異なる。

## 学習の使用例

作業場所は`GyaimSwift/Tools/model-training/`。Python 3.12の学習用venvを使用する。
以下のパスはこのPCの配置例であり、データ・重みはGitに含めない。

```powershell
.venv/Scripts/python.exe prepare_context_training.py `
  --domain data/issue-125/source/domain-2026-11.jsonl `
  --context-cases data/issue-125/source/context-cases-2026-10.jsonl `
  --holdout data/issue-125/source/domain-valid.jsonl `
  --holdout data/issue-125/source/rerank-valid.jsonl `
  --output data/issue-125/prepared-v2
```

`--public`は事前抽出した公開リプレイを複数指定できる。全コーパスを読み込まず、
メモリに収まるサブセットを使う。oversamplingは分割後に行い、既定は1。
`--context-policy long-context`は元文脈11文字以上、末尾20文字だけの比較条件。

候補蒸留は、同じpairs・固定ケース・holdout・seedで生成した教師cacheを使う。
教師cacheの全ペア対応・有限値・元pairsのhash・教師識別情報を検証する。
`context_distill`は教師の文脈あり平均logprob差のsigmoidをsoft targetとしたBCEに、
学習前の生徒の文脈なしスコアとのMSEを加える。全語彙のtoken KLではない。

候補Vの実設定:

| 項目 | 値 |
|---|---|
| 初期値 | tanabe1478/gyaim-lm-small-public-v1 |
| 教師 | Miwa-Keita/zenz-v2.5-medium |
| objective / scope / precision | context_distill / all / fp32 |
| steps / learning rate / seed | 1000 / 5e-6 / 125 |
| dropout / anchor / prior-preservation | 0.1 / 0 / 1 |
| deterministic-prior | false |
| train / validation | 8,987 / 2,878 |
| checkpoint選択 | pair_quality、25stepsごと、選択825 |
| validation accuracy / loss | 0.8488533704 / 0.3511473536 |

Vのpoolは、公開UD/Tatoeba由来の対比・文脈長変種・レビュー済みの公開例から作成した
Uのpool（train9,235、validation2,878）から上記248件を除いたもの。
pool準備用の実験スクリプト、教師cache、詳細ログはローカルの`data/issue-125/`と
`runs/issue-125/`に保持している。このPRはそれらのデータ成果物を配布しない。
選択checkpointとfinalの重み一致、実1,000steps完了、pool/cache設定の監査は合格した。

`--dropout`省略時は元configを維持する。`--deterministic-prior`は蒸留専用で、
文脈なしforwardだけeval modeにして勾配を保持し、各moduleの状態を必ず復元する。
gradient checkpointingとの併用は拒否する。この比較条件Tは固定評価で改善せず未採用。
学習途中の停止は`STOP_REQUESTED`かCtrl-Cでcheckpointを保存し、finalは発行しない。

## 評価の使用例

```powershell
.venv/Scripts/python.exe evaluate_context_cases.py `
  --cases data/issue-125/source/context-cases-2026-10.jsonl `
  --hf-model runs/issue-125/v-consistent-short-distill-fp32-v1/final `
  --precision fp32 --output runs/issue-125/v-recheck-new

.venv/Scripts/python.exe compare_context_runs.py `
  --cases data/issue-125/source/context-cases-2026-10.jsonl `
  --baseline runs/issue-125/baseline-public/context-eval-fp32/scores.json `
  --trial runs/issue-125/v-recheck-new/scores.json `
  --output runs/issue-125/v-recheck-new/comparison.json
```

候補順・候補数（最大24）を保持し、候補外truthと採点不能も失敗として母数に含める。
候補あり・truthありの全例×4長のcoverageとcase hashを検証し、欠落・重複を拒否する。
`allContextLengthsImproved`は点推定の判定だけで、採用フラグではない。

nativeケース別scoreを集計する場合は`--score-export`で以下の形式を渡す。
既存Macハーネスの集計reportとは別形式。今回追加したnative traceも別schemaであり、
上記の旧HF互換exportには変換しない。native traceは`analyze_native_context.py`で分析する。

```json
{
  "casesSha256": "SHA256 of original JSONL bytes",
  "backend": "LlamaZenzContext.scoreBatch",
  "model": "versioned model identifier and GGUF SHA256",
  "records": [{
    "caseIndex": 0,
    "caseHash": "evaluate_context_cases.case_hash(case)",
    "contextLength": 20,
    "scores": [-1.0, -2.0],
    "productionScores": [-1.0, 0.0],
    "productionOrder": [1, 0]
  }]
}
```

productionOrderはSwiftのllmPrimaryOrderを通した完全な候補indexの順列で、
heuristic同点処理・安全規則・辞書からのcompound復元を省略しない。
production値が全件揃わない場合は本番Top-1をnullにし、近似値で埋めない。

## Mac検証用のローカル成果物

`runs/issue-125/v-mac-handoff-v1/issue-125-v-mac-eval.zip`（147,763,087 bytes）に
公開baseとVのQ5、元モデルカード、hash、実行手順と比較スクリプトを同梱した。
学習文・固定評価ケースは含めない。
2026-11-04、ユーザーの依頼でモデルとZIPを専用のprivateモデルrepo
[tanabe1478/gyaim-lm-small-context-v1](https://huggingface.co/tanabe1478/gyaim-lm-small-context-v1)
へアップロードした。revisionは`2476e1f9e9b290e43769eb9ecf1cccbbdb3ad2c1`。
HF形式の重み・tokenizer、Q5、Mac比較ZIP、出典とmanifestの15ファイルについて、
remoteのサイズとSHA256を照合済み。private設定と匿名アクセス拒否も確認した。
ZIP自体は作成時のスナップショットを維持しているため、内部READMEの未アップロード表記は当時の記録。

アクセスできるHFアカウントでMacにログインし、次で取得できる:

```bash
hf download tanabe1478/gyaim-lm-small-context-v1 mac-eval/issue-125-v-mac-eval.zip --revision 2476e1f9e9b290e43769eb9ecf1cccbbdb3ad2c1 --local-dir ./gyaim-context-v1
```

展開後、既存の10月ケースがあるMacで実行する:

```bash
bash /path/to/extracted/run-mac-eval.sh /path/to/SwiftyGyaim/GyaimSwift
```

ケースの既定パスは`~/.gyaim/eval/context-cases-2026-10.jsonl`。
`GYAIM_CONTEXT_EVAL_CASES`で変更できる。既存Releaseハーネスを両モデル・全件/gap30で使い、
件数・重み・heuristicが同じことを確認して`results.*/comparison.json`へ集計する。
nativeは候補外truth6件を除く11,066件で、gap条件は>30秒。HFの>=30秒と区別する。
ZIPの各ファイルhash/CRC、Bash構文、Python構文、合成reportでの比較は確認済み。
このZIPのMac実行は2026-11-04のIssueコメントで完了を確認した（本番式20文字は退行）。
追加したケース別trace機能は、この元ZIPには含まれない。更新したcloneで診断を実行する。

## 成果物のSHA256

| 成果物 | SHA256 |
|---|---|
| 固定ケース | `ac6aa258eb2a8f6c692d95958e63b10c9c9e4536b7683b04efaa03d879a46c7c` |
| 公開base Q5 | `f8f9180c1f751092b6298a4df13f7e20cbf487d4f2af6f89727605c4f4bed860` |
| V FP32 | `6ce5b33ab33de9fedb3759dfa35652de9a39eeeea2c43533984b58580b97482c` |
| V Q5 | `4de6eb85a50ed86ae941c0bc77967684eac79efdfdaf4f4ae731e584ad270d44` |
| V pool | `e9739ce243c6a7a704c74835c42d939036ec64887d37a36ed99e2b5c5798d95a` |
| V teacher cache | `3acadc79b0f13f27aab688f425a55db9e5e95538ea5782dfe9369e1b5d55520b` |
| Mac検証ZIP | `c422c3d3d2327802419d53dc8a187ab4e9b3cfdfb86ac6906f51c84c42849ec5` |

変換はazooKey/llama.cpp commit88b97a47dc7f5892e2d5a6856fbe9cfe237f9e5c、F16経由Q5_K_M。
実験の詳細履歴はローカル`runs/issue-125/experiment-history-through-v.md`へ保存した。

## テスト

```powershell
.venv/Scripts/python.exe -m unittest test_context_training.py test_context_preference.py test_context_prior.py
```

合成例のみを使い、split隔離、固定評価coverage、前処理の相違、completion/padding mask、
損失の勾配方向、教師cacheの完全性、dropout設定、mixed-modeの状態復元を検証する。
Macの`Scripts/run-unit-tests.sh`にも接続した。torch/transformers依存のテストは学習venvがある場合に実行する。
Windowsで上記に既存の`test_train_zenz.py`・`test_build_sft_dataset.py`・
`test_compare_hf_gguf.py`を合わせた41テストが成功。PythonコンパイルとBash構文検証も成功。
Xcode/Swiftのビルド・テストはこのWindows上では未実行。
