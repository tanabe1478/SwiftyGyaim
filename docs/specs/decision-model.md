# Spec: Gyaim Decision Model development

> Trigger: Tools/decision-model/
> Last updated: 2026-09-19

## Scope

Windows GPUでcandidate-selectionモデルのdata build、学習、校正、評価、exportを行う。
Swift推論・UI・AIRerankBackendの置換は対象外。既存gyaim-lmは比較baselineとして維持する。
詳細な設計判断は [ARCHITECTURE.md](../../GyaimSwift/Tools/decision-model/ARCHITECTURE.md)、
実行手順は [README.md](../../GyaimSwift/Tools/decision-model/README.md) を参照する。

## Contract

- schemaVersion=1。stateはcontext/readingRoman/readingHiragana。
- actual候補数は1〜24、NONEはJSONでselected=null、tensorで固定index24。
- 候補はtext/reading/source/kind/originalRank/studyFrequency/contextAffinity/exactReadingMatch。
  不明なmetadataはnullとpresence maskで明示し、frequency=0等と混同しない。
- encoderは非因果的。候補文字列・候補index・候補順序は生成せず25 logitsを返す。
- paddingはtext pooling、set attention、lossから除外。候補並べ替え時はlogitsも対応して並べ替わる。
- tokenizer.jsonとNFC/空白変換/Unicode scalar単位のtokenization契約をhash・golden vectorsとともに配布。

## Data boundary

公開学習はzenz公開JSONLと同梱辞書のみ。既存domain/dogfood由来ファイルは読まない。
Privateは明示指定・timestamp必須・時間順splitとし、派生run/artifactを含めprivate/以下へ隔離する。
Privateを公開artifactへexportしない。例文・候補・入力文脈をtraining logへ出力しない。

公開splitはcontext group単位（空contextはreading単位）で85/5/5/5。
regression fixtureのreadingは開発4splitから全除外。NONE派生は親と同じsplit。
辞書由来hard negative→prefix→kanaの順で候補集合を作る。random negativeは使わない。
goldを自身の学習候補辞書へ足すself-miningは禁止（BUG-040）。

現builderは競合する短い読みの辞書集合に条件付けた評価である。接続グラフ全体・学習辞書・
実候補生成・ユーザーの入力途中を完全再現していない。Candidate Recall@24を本番の包括的な
Recallと表現しない。破棄件数・サンプリング方法・母集団の制約をreportへ残す。

## Training and evaluation

Windows上の既存ROCm/CUDA venvを再利用する。GPU不在時の暗黙CPU fallbackは禁止。
config・seed・git SHA/dirty・code/data/tokenizer hashes・device/library versionsを保存する。
checkpointにoptimizer/scheduler/scaler/RNG/epoch/次batch位置を含める。再開前にhashを検証する。

checkpoint/model選定はvalidation MRR + 0.25 NONE F1。test/regressionを選定へ利用しない。
温度校正は独立calibration splitのみで行い、別ファイルにmodel hashと保存する。
候補内ランキングとNONE判定を別集計する。heuristicとHF版gyaim-lmは同一候補集合で比較する。
候補の元順と既存Python heuristicの順は区別する。HF baselineのNONEはunsupportedと明記する。

## Artifact and acceptance

FP32 PyTorch、FP32 ONNX、FP16 weights、dynamic INT8 ONNX、tokenizer/spec/vectors、manifest、
calibration、評価・速度・量子化report、model card、参照推論コードを一directoryにまとめる。
exportはstagingで検証し、全成功後にdirectoryを確定する。ONNX parityはcandidate数1/3/8/24、
batch1/2でlogits誤差とargmaxを検証する。量子化はvalidationで精度/ECE/size/latencyを測定する。

合成公開データだけではproduction採用を承認しない。manifestにquality gate結果と
research-not-approvedを明記する。Core ML実行検証と本体統合はmacOS側の別タスクである。
