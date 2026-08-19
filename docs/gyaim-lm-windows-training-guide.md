# gyaim-lm を Windows + Radeon で学習する手順

> 対象: 機械学習を初めて触る開発者  
> 対象PR: [#93 特化モデル学習](https://github.com/tanabe1478/SwiftyGyaim/pull/93)  
> 実測日: 2026-08-16  
> 実測機: Ryzen 7 9800X3D / RAM 32GB / Radeon RX 9070 XT 16GB / Windows 11

この文書は、PR #93 のモデル学習をMacからWindowsへ引き継いだときの実作業を、
再現できる形で説明する。コマンドだけでなく、何をしているのか、結果をどう判断するのかも扱う。

## 1. 今回作るもの

gyaim-lm は、SwiftyGyaimのかな漢字変換候補を評価するための小さな言語モデルである。
元モデル `ku-nlp/gpt2-small-japanese-char` から、次の2種類のデータを使って追加学習する。

1. 公開データ: `Miwa-Keita/zenz-v2.5-dataset`
2. ドメインデータ: SwiftyGyaimの実利用ログから抽出・redactionした変換ペア

「追加学習」は、すでに日本語の文字列を扱えるモデルへ、SwiftyGyaimで重要な変換パターンを
覚えさせる作業である。このPRではSFT（Supervised Fine-Tuning、教師あり微調整）を行う。

学習データ1行の概念は次のとおり。

```json
{"input":"キョウカイセン","output":"境界線","left_context":"モデルの"}
```

- `input`: 読み。カタカナで保持する
- `output`: 正解として学習させる確定表記
- `left_context`: 入力位置より左側の文脈。存在しない場合もある

## 2. 最初に知っておく用語

| 用語 | この作業での意味 |
|---|---|
| base model | 学習開始時点の元モデル。今回は `ku-nlp/gpt2-small-japanese-char` |
| train | モデルの重み更新に使うデータ |
| valid | 学習には使わず、未知データに対するlossを測るデータ |
| domain-valid | ユーザー固有語彙に近いデータのうち、学習から除外して効果測定に使う60件 |
| epoch | train全体を一巡すること。今回は1 epoch |
| batch size | 1回の重み更新でまとめて処理する件数。今回は32 |
| step | 1 batchを処理して重みを更新する単位 |
| loss | モデルの予測誤差。条件が同じなら小さいほどよい |
| exact match | 生成結果が正解文字列と完全一致した割合 |
| checkpoint | 途中再開できるように保存したモデルと学習状態 |
| FP32 | 32-bit浮動小数点。精度は高いが学習が遅く、VRAM使用量も多い |
| FP16 | 16-bit浮動小数点を使う混合精度学習。対応GPUでは高速で省メモリ |
| GGUF | 学習後のモデルをSwiftyGyaim内のllama.cpp系runtimeで読むための形式 |

`loss` は単独の絶対値だけで良否を判断しない。学習中に下がっているか、valid lossが悪化して
いないか、実際のfixtureやdomain-validで正解数が増えたかを組み合わせて判断する。

## 3. Windowsを使う理由

Mac M5での既存実測は約15.7 examples/sで、100万件に18〜20時間かかっていた。
RX 9070 XTはFP16演算が速く、実測では500 stepを226 examples/sで処理できた。

| 条件 | 実測 | 100万件の単純推定 |
|---|---:|---:|
| Mac M5 / 既存mixed-v1 | 15.7 examples/s | 18〜20時間（既存実測） |
| RX 9070 XT / FP32 | 約27 examples/s | 約10.4時間 |
| RX 9070 XT / FP16、101 step | 180.6 examples/s | 約93分 |
| RX 9070 XT / FP16、501 step | **226 examples/s** | **約75分** |
| RX 9070 XT / FP16、本番実測 | **236.2 examples/s** | **71分32秒** |

501 stepのFP16学習ではlossが2.135から1.177まで下がり、NaNやGPUエラーは発生しなかった。
1.9億件を1 epoch処理する単純推定は約9.7日だが、フル学習を行うかは今回の100万件モデルを
評価してから判断する。

### タスクマネージャーで余って見える理由

タスクマネージャーの既定GPUグラフは「3D」で、機械学習に使うHIP computeの負荷を表さない。
グラフ名をクリックして `Compute 0` を選ぶか、WindowsのGPU Engineカウンターを確認する。

mixed-v1実行中に3秒間測定した結果、学習プロセスの `Compute 0` は平均93.6%、最大98.2%だった。
したがって、GPUの計算器はすでにほぼ上限まで使えている。CPU・RAM・VRAMに空きがあるのは
異常ではない。このsmallモデルでは、全PC資源を100%にすることより、最も遅いGPU computeを
継続的に働かせることが重要である。

batch sizeを64や128へ増やせば数%改善する可能性はあるが、1 stepで見る例数が変わり、
既存Macレシピとの品質比較やlearning rateの意味も変わる。GPU computeがほぼ飽和している今回は、
速度だけのために学習条件を変更せずbatch 32を維持した。

## 4. cloneとブランチの確認

作業ディレクトリが空であることを確認してから、PRのheadブランチを直接cloneした。

```powershell
git clone --branch feature/zenz-specialized-training --single-branch `
  https://github.com/tanabe1478/SwiftyGyaim.git .
git status --short --branch
```

期待する表示:

```text
## feature/zenz-specialized-training...origin/feature/zenz-specialized-training
```

最初はSSH URLも試したが、このWindowsにGitHub用公開鍵が登録されておらず
`Permission denied (publickey)` になった。HTTPS cloneならこの問題を避けられる。

## 5. ROCm版PyTorchを準備する

### 5.1 ROCmとPyTorchの関係

PyTorchは学習処理を書くためのライブラリ、ROCm/HIPはPyTorchからAMD GPUを使うための層である。
ROCm版PyTorchでも歴史的な互換性のためAPI名は `torch.cuda` のままになっている。
ログに `device=cuda` と出てもNVIDIA GPUを使っているという意味ではない。

2026-08-16時点では、AMD公式のWindows版PyTorch 2.9.1 + ROCm 7.2.1が
RX 9070 XT（gfx1201）、Windows 11、Python 3.12をサポートしている。

- [AMD: Windows support matrix](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityrad/windows/windows_compatibility.html)
- [AMD: PyTorch via PIP installation](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installryz/windows/install-pytorch.html)

公式要件はAMD Software 26.2.2以降。この機体ではGPUドライバ
`32.0.31021.5001`（2026-06-28）を確認した。

### 5.2 venvを作る

venvは、このプロジェクト専用のPython環境である。システム全体のPythonパッケージと混ざらず、
失敗しても `.venv` を作り直せる。

```powershell
cd GyaimSwift\Tools\model-training
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip wheel
```

`.venv/` は `.gitignore` 済みで、commitしない。

### 5.3 AMD公式wheelを入れる

wheelは、コンパイル済みPythonパッケージである。以下はAMD公式のROCm 7.2.1配布物を使う。

```powershell
.\.venv\Scripts\python.exe -m pip install --no-cache-dir `
  "https://repo.radeon.com/rocm/windows/rocm-rel-7.2.1/rocm_sdk_core-7.2.1-py3-none-win_amd64.whl" `
  "https://repo.radeon.com/rocm/windows/rocm-rel-7.2.1/rocm_sdk_devel-7.2.1-py3-none-win_amd64.whl" `
  "https://repo.radeon.com/rocm/windows/rocm-rel-7.2.1/rocm_sdk_libraries_custom-7.2.1-py3-none-win_amd64.whl" `
  "https://repo.radeon.com/rocm/windows/rocm-rel-7.2.1/rocm-7.2.1.tar.gz"

.\.venv\Scripts\python.exe -m pip install --no-cache-dir `
  "https://repo.radeon.com/rocm/windows/rocm-rel-7.2.1/torch-2.9.1%2Brocm7.2.1-cp312-cp312-win_amd64.whl"

.\.venv\Scripts\python.exe -m pip install transformers accelerate datasets
```

ROCm SDKは約1.4GB、PyTorch wheelは約0.8GBある。十分な空き容量と安定した回線が必要。

### 5.4 GPUを検証する

「GPU名が表示できた」だけでなく、実際にGPU上で行列積を完了できることまで確認する。

```powershell
.\.venv\Scripts\python.exe -c "import torch; print(torch.__version__); print(torch.version.hip); print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0)); x=torch.randn((2048,2048),device='cuda'); y=x@x; torch.cuda.synchronize(); print(y.shape)"
```

この機体の実測:

```text
2.9.1+rocm7.2.1
7.2.53211-158bd99533
True
AMD Radeon RX 9070 XT
torch.Size([2048, 2048])
```

## 6. 本番前に500 stepベンチを行う

### 6.1 小さなデータを作る

```powershell
.\.venv\Scripts\python.exe prepare_dataset.py `
  --wikipedia 20000 --llm-jp 10000 --valid 100 --output data-bench
```

生成結果はtrain 29,900件、valid 100件。`data-bench/` もGit管理外である。

### 6.2 FP16で約500 stepだけ学習する

29,900 ÷ batch 32 ≒ 934 stepで1 epochになる。`0.535 epoch` にすると約501 stepになる。

```powershell
$env:PYTHONUTF8 = '1'
.\.venv\Scripts\python.exe train_zenz.py `
  --train data-bench\train.jsonl `
  --output runs\bench-windows-fp16-500 `
  --epochs 0.535 `
  --batch-size 32 `
  --max-length 192 `
  --save-steps 10000 `
  --fp16
```

最終行付近の `train_samples_per_second` が比較に使うexamples/sである。

```text
train_runtime: 70.78
train_samples_per_second: 226
train_steps_per_second: 7.079
train_loss: 1.452
```

FP32では約1.16秒/stepだったが、FP16では約7.1 step/sになった。この差が大きいため、
RX 9070 XTで本番学習するときは `--fp16` を付ける。

## 7. 本番データを再生成する

```powershell
.\.venv\Scripts\python.exe prepare_dataset.py `
  --wikipedia 700000 `
  --llm-jp 300000 `
  --valid 5000 `
  --domain data\domain.jsonl `
  --domain-oversample 30 `
  --domain-valid 60 `
  --output data
```

2026-08-16の最新ブランチでの件数:

| ファイル | 件数 | 用途 |
|---|---:|---|
| `data/train.jsonl` | 1,013,720 | 重み更新 |
| `data/valid.jsonl` | 5,000 | valid loss |
| `data/domain-valid.jsonl` | 60 | ドメインexact match |
| `data/domain.jsonl` | 684 | redaction済みドメインデータの原本 |

trainの内訳は公開データ995,000件と、domain-validを除いた624件 × 30回 = 18,720件。
PR本文の古い件数1,011,500との差は、ドメイン原本が更新されたためである。

## 8. mixed-v1本番学習

フォアグラウンドで実行する場合:

```powershell
.\.venv\Scripts\python.exe train_zenz.py `
  --train data\train.jsonl `
  --valid data\valid.jsonl `
  --output runs\mixed-v1 `
  --epochs 1 `
  --batch-size 32 `
  --max-length 192 `
  --lr 1e-4 `
  --save-steps 4000 `
  --fp16
```

バックグラウンド実行では、標準出力と進捗・警告を別ログへ保存する。

```powershell
$workDir = (Resolve-Path '.').Path
$pythonExe = (Resolve-Path '.\.venv\Scripts\python.exe').Path
$env:PYTHONUTF8 = '1'
$env:PYTHONUNBUFFERED = '1'

Start-Process `
  -FilePath $pythonExe `
  -ArgumentList @(
    'train_zenz.py',
    '--train', 'data\train.jsonl',
    '--valid', 'data\valid.jsonl',
    '--output', 'runs\mixed-v1',
    '--epochs', '1',
    '--batch-size', '32',
    '--max-length', '192',
    '--lr', '1e-4',
    '--save-steps', '4000',
    '--fp16'
  ) `
  -WorkingDirectory $workDir `
  -RedirectStandardOutput (Join-Path $workDir 'runs\mixed-v1-windows.stdout.log') `
  -RedirectStandardError (Join-Path $workDir 'runs\mixed-v1-windows.stderr.log') `
  -WindowStyle Hidden
```

進捗確認:

```powershell
Get-Content runs\mixed-v1-windows.stdout.log -Tail 20
Get-Content runs\mixed-v1-windows.stderr.log -Tail 20
Get-ChildItem runs\mixed-v1\checkpoint-*
```

このrunは31,679 step。2026-08-16 01:32ごろに開始し、02:43ごろに正常終了した。
実測は71分32秒、236.2 examples/s、7.381 step/sだった。500 stepの短いベンチより本番が
少し速いのは、開始直後の準備時間が全体に占める割合が小さくなったためである。

学習の最終結果:

| 指標 | 結果 |
|---|---:|
| train runtime | 4,292秒（71分32秒） |
| train samples/s | 236.2 |
| train steps/s | 7.381 |
| train loss（全体平均） | 0.2328 |
| valid loss | 0.1167 |
| valid perplexity | 1.12 |

`save_total_limit=2` のため、途中checkpointは最後の
`checkpoint-28000` と `checkpoint-31679` だけが残る。学習完了後は
`runs/mixed-v1/final/` が配布用のHFモデルである。

### 8.1 Windowsを別用途で使うときの安全な停止・再開

停止・再開は可能である。学習中のモデルは単なる1ファイルではなく、次の状態をまとめて
`checkpoint-*`へ保存する必要がある。

| 保存するもの | 保存する理由 |
|---|---|
| model weights | その時点までにモデルが覚えた内容 |
| optimizer | 次の重み更新を同じ条件で続けるため |
| learning-rate scheduler | learning rateの途中経過を保つため |
| 乱数状態 | データ順や計算を再現するため |
| JSONLのbyte位置・shuffle buffer | 1.9億件の先頭から読み直さず、次の学習例から続けるため |

#### 推奨: 停止要求ファイルを作る

バックグラウンド学習を止めたい場合、別のPowerShellで次を実行する。

```powershell
New-Item runs\zenz-v2.5-full\STOP_REQUESTED -ItemType File -Force
```

スクリプトは現在のoptimizer stepを最後まで処理し、checkpointを保存してから正常終了する。
ログに次が出るまで待つ。

```text
stop requested; saving a resumable checkpoint after step ...
graceful stop complete; resume checkpoint=...\checkpoint-...
```

PowerShellの前面で動かしている場合は `Ctrl+C` でも同じ安全な停止処理になる。
モデル保存はこの実測機で数秒程度かかるため、キーを押してすぐプロセスを強制終了しない。

#### 再開

開始時と**同じ引数**に `--resume` だけを追加する。最新の`checkpoint-*`を自動選択し、
モデル・optimizer・scheduler・データ位置を復元する。

```powershell
.\.venv\Scripts\python.exe train_zenz.py `
  --train data\train.jsonl --valid data\valid.jsonl `
  --output runs\mixed-v1 --epochs 1 --batch-size 32 --max-length 192 `
  --lr 1e-4 --save-steps 4000 --fp16 --resume
```

1.9億件のstreaming学習では、`--max-steps`、`--shuffle-buffer`、入力ファイルの順番も
開始時と同一にする。スクリプトは入力ファイルやshuffle buffer設定がcheckpointと違う場合、
誤った位置から再開せずエラーで止まる。

#### 強制終了しかできない場合

タスクマネージャーの「タスクの終了」、`Stop-Process -Force`、Windowsの再起動や電源断では、
その瞬間の状態は保存できない。それでも `--save-steps` ごとの定期checkpointから再開できる。
たとえば実測7.38 step/sで `--save-steps 4000`なら、最悪でも約9分ぶんをやり直す。

Windowsをゲーム、動画処理、GPUを使う開発などへ確実に空けたい場合は、まず上記の安全な停止を
行う。Web閲覧や文書作成程度なら学習を動かしたままでもよいが、画面が重ければ停止して構わない。
停止と再開を行っても、それまでの数日分が失われることはない。

### 8.2 1.9億件を扱うstreamingモード

100万件版は全行をRAMへ読み込めたが、約1.9億件を同じ方法で扱うと32GB RAMを大きく超える。
`--streaming`はJSONLを少しずつ読み、最大`--shuffle-buffer`件だけをメモリに置く。

まず公開データ2ファイル（合計約36.5GB）を取得する。Hugging Face CLIは`.venv`内にある。
同じコマンドを再実行すると、完了済み部分を利用してdownloadを続けられる。

```powershell
.\.venv\Scripts\hf.exe download Miwa-Keita/zenz-v2.5-dataset `
  train_wikipedia.jsonl train_llm-jp-corpus-v3.jsonl `
  --repo-type dataset --local-dir data-full
```

```powershell
.\.venv\Scripts\python.exe train_zenz.py `
  --train data-full\train_wikipedia.jsonl data-full\train_llm-jp-corpus-v3.jsonl `
  --train-counts 17493369 171487973 `
  --valid data\valid.jsonl `
  --output runs\zenz-v2.5-full `
  --streaming --max-steps 5905667 `
  --batch-size 32 --max-length 192 --lr 1e-4 `
  --shuffle-buffer 10000 --logging-steps 500 `
  --save-steps 4000 --eval-steps 100000 --fp16
```

`--train-counts`を渡すと、両ファイルがそれぞれ同じ割合で進むように交互に読み取る。
たとえばWikipediaが全体の約2割なら、おおむね5件に1件がWikipediaになる。これにより、
最初にWikipediaだけ、後半にCommon Crawlだけを学ぶデータ源の偏りを避ける。各ファイルの
読取位置と残り件数もcheckpointに入る。

`max_steps = ceil(総行数 / (batch-size × grad-accum))` である。ファイルの正確な行数を数えてから
値を確定する。全行をRAMへ載せずに行数と`max_steps`を計算するコマンドは次のとおり。

```powershell
.\.venv\Scripts\python.exe count_jsonl.py `
  data-full\train_wikipedia.jsonl data-full\train_llm-jp-corpus-v3.jsonl `
  --batch-size 32
```

2026-08-16にdownloadした実ファイルの結果:

| ファイル | 行数 |
|---|---:|
| `train_wikipedia.jsonl` | 17,493,369 |
| `train_llm-jp-corpus-v3.jsonl` | 171,487,973 |
| 合計 | **188,981,342** |
| batch 32で1巡するstep | **5,905,667** |

開始時に`runs/zenz-v2.5-full/run_manifest.json`を自動保存する。再開時に入力ファイル、
行数、batch size、learning rate、`max_steps`などが変わっていれば、誤学習を避けるため
`--resume`はエラーで停止する。

checkpointは約1.1GBで、`save_total_limit=2`により通常は最新2個だけを保持する。
shuffle bufferそのものと乱数状態も保存するので、安全停止後の次の学習例は停止しなかった場合と
一致する。小規模テストでは、停止後に比較した次の20件が20/20で一致した。

- `--logging-steps 500`: 約1分ごとにtrain lossを記録する
- `--eval-steps 100000`: 約3時間45分ごとにvalid lossを測る（実測速度からの推定）
- `--save-steps 4000`: 約9分ごとに再開用checkpointを保存する

実データ500-stepベンチは66.96秒、238.9 examples/s、7.467 step/sだった。この速度を
188,981,342件へ単純換算すると約9.15日である。実際には定期評価とcheckpoint保存が加わるため、
完了見込みは約9〜10日とする。

本番は2026-08-16 04:03（JST）にバックグラウンドで開始した。

| 項目 | パス / 値 |
|---|---|
| output | `runs/zenz-v2.5-full` |
| 標準出力 | `runs/zenz-v2.5-full.stdout.log` |
| 進捗・警告 | `runs/zenz-v2.5-full.stderr.log` |
| 停止要求 | `runs/zenz-v2.5-full/STOP_REQUESTED` |
| 単純ETA | 2026-08-25朝〜昼ごろ（定期評価を含むと前後する） |

04:12に最初の`checkpoint-4000`が完成した。model、optimizer、scheduler、FP16 scaler、
RNG、JSONL読取位置、10,000件のshuffle bufferがすべて存在することを読み戻して確認した。
checkpoint保存後も学習プロセスは正常に継続している。

### 8.3 Windows再起動からの実復旧記録

2026-08-16 06:34ごろ、Windowsの再起動によって学習プロセスが強制終了した。ログ上は
step 72,857まで進んでおり、最新の完全な定期保存は`checkpoint-72000`だった。

07:48に次を確認してから`--resume`で再開した。

- `trainer_state.json`のglobal stepが72,000
- model、optimizer、scheduler、FP16 scaler、RNGがすべて存在
- Wikipedia 214,203行、llm-jp 2,099,829行までの読取位置を保存
- 10,000件のshuffle bufferを保存
- checkpoint全体は約1.09GB

再開ログに`restored streaming data position from ...checkpoint-72000`が出た後、step 72,001以降を
処理し、約7.7 step/sへ復帰した。再開後500件のlossは0.1418で、再起動前の0.14台と連続している。
失われたのは72,001〜72,857の857 step、約1分45秒ぶんだけであり、それ以前の学習は失われなかった。

### 8.4 別用途でPCを使うための安全停止記録

2026-08-16 19:32（JST）、Windowsを別用途へ空けるため、
`runs/zenz-v2.5-full/STOP_REQUESTED`を作成して安全停止を要求した。
学習ループは実行中のstepを完了してから停止要求を消費し、step 421,052で
`checkpoint-421052`を保存して正常終了した。

停止後、学習用Pythonプロセスが0件であることに加え、再開に必要な次のファイルを確認した。

- `model.safetensors`
- `optimizer.pt`
- `scheduler.pt`
- `trainer_state.json`（`global_step: 421052`）
- `training_args.bin`
- `rng_state.pth`
- `dataset_state.pt`

次回は8.2節と同じコマンドへ`--resume`を付けて実行する。スクリプトが
`checkpoint-421052`を自動選択し、モデルだけでなくoptimizer、乱数、shuffle buffer、
巨大JSONLの読取位置も復元する。

2026-08-17 00:42（JST）に、同じ学習引数と`--resume`で再開した。ログは次の2ファイルに
分け、バックグラウンドの非表示プロセスとして起動した。

- `runs/zenz-v2.5-full.resume-20260817-004249.stdout.log`
- `runs/zenz-v2.5-full.resume-20260817-004249.stderr.log`

標準出力の`restored streaming data position from ...checkpoint-421052/dataset_state.pt`と、
進捗がstep 421,053以降へ進んだことを確認した。CUDA・FP16で約8 step/sに復帰し、
Traceback、Out of Memory、NaNなどの重大エラーは発生していない。

### 8.5 進捗報告後の2回目の安全停止記録

2026-08-17 22:19（JST）、step 1,060,876（全体の約18.0%、約3,395万件処理済み）で
進捗を報告した後、`STOP_REQUESTED`で安全停止を要求した。実行中のstepを完了し、
step 1,060,954で`checkpoint-1060954`を保存して正常終了した。

学習用Pythonプロセスが0件になったことと、model、optimizer、scheduler、training args、
乱数状態、trainer state、streaming dataset stateの7種類が揃っていることを確認した。
`trainer_state.json`の`global_step`も1,060,954である。次回の`--resume`はこのcheckpointを
自動選択するため、今回の安全停止によるstepの巻き戻りはない。

2026-08-18 03:22（JST）に、同じ学習引数と`--resume`で2回目の再開を行った。今回は
Python起動から最初のログまで約2分半かかったが、プロセスは応答を維持しており、03:25に
`checkpoint-1060954/dataset_state.pt`からのデータ位置復元を確認した。その後、step 1,060,955
以降へ進み、CUDA・FP16で学習を継続している。重大エラーは発生していない。

再開ログ:

- `runs/zenz-v2.5-full.resume-20260818-032237.stdout.log`
- `runs/zenz-v2.5-full.resume-20260818-032237.stderr.log`

### 8.6 3回目の安全停止記録

2026-08-18 20:24（JST）、`STOP_REQUESTED`で安全停止を要求した。実行中のstepを完了し、
step 1,563,801（全体の約26.5%、約5,004万件処理済み）で`checkpoint-1563801`を保存して
正常終了した。

学習用Pythonプロセスが0件になったことと、model、optimizer、scheduler、training args、
乱数状態、trainer state、streaming dataset stateがすべて揃っていることを確認した。
`trainer_state.json`の`global_step`は1,563,801であり、次回は`--resume`によってこの位置から
巻き戻りなく再開できる。

2026-08-19 01:04（JST）に`checkpoint-1563801`から3回目の再開を行った。PythonとGPUの
初期化後、`dataset_state.pt`からstreamingデータ位置を復元し、step 1,563,802以降への進行を
確認した。直後のstep 1,564,000で新しい定期checkpointも正常に保存され、その後もCUDA・FP16で
学習を継続している。重大エラーは発生していない。

再開ログ:

- `runs/zenz-v2.5-full.resume-20260819-010442.stdout.log`
- `runs/zenz-v2.5-full.resume-20260819-010442.stderr.log`

### 8.7 進捗報告後の4回目の安全停止記録

2026-08-19 20:49（JST）、step 2,148,062（全体の約36.4%、約6,874万件処理済み）、
学習loss 0.06749、最新valid loss 0.06697と報告した後、`STOP_REQUESTED`で安全停止を
要求した。実行中のstepを完了し、step 2,148,120で`checkpoint-2148120`を保存して正常終了した。

学習用Pythonプロセスが0件になったことと、model、optimizer、scheduler、training args、
乱数状態、trainer state、streaming dataset stateがすべて揃っていることを確認した。
`trainer_state.json`の`global_step`は2,148,120であり、次回はこの位置から再開できる。

2026-08-20 02:50（JST）に`checkpoint-2148120`から4回目の再開を行った。Python・GPUの
初期化後、`dataset_state.pt`からstreamingデータ位置を復元し、step 2,148,121以降を
約8 step/sで処理していることを確認した。CUDA・FP16で正常に動作し、重大エラーはない。

再開ログ:

- `runs/zenz-v2.5-full.resume-20260820-025022.stdout.log`
- `runs/zenz-v2.5-full.resume-20260820-025022.stderr.log`

進捗確認:

```powershell
Get-Content runs\zenz-v2.5-full.stdout.log -Tail 20
Get-Content runs\zenz-v2.5-full.stderr.log -Tail 5
Get-ChildItem runs\zenz-v2.5-full\checkpoint-*
```

## 9. 学習後の評価

評価は「loss」「一般fixture」「ドメインexact match」の3方向から見る。

### 9.1 valid loss

`train_zenz.py` は学習終了後にvalid 5,000件を評価する。今回の結果は次のとおり。

```text
valid loss=0.1167 ppl=1.12
```

学習lossだけが下がりvalid lossが悪化する場合は、trainデータを暗記する過学習の可能性がある。

### 9.2 fixture 122件

```powershell
.\.venv\Scripts\python.exe compare-hf-gguf.py `
  --backend hf `
  --hf-model runs\mixed-v1\final `
  --json
```

今回のHFモデルは **84/122（68.85%）**。現行zenz-v3.1-smallの基準80/122より4件多く、
xsmallの77/122より7件多かった。ただし差は大きくないため、量子化後とアプリ内ルール込みの
評価も続ける。

### 9.3 domain-valid 60件

まず元モデルを同じ60件で測り、学習前の基準値を保存する。

```powershell
.\.venv\Scripts\python.exe evaluate_domain_valid.py `
  --model ku-nlp/gpt2-small-japanese-char `
  --data data\domain-valid.jsonl `
  --json
```

次に、学習済みモデルを測る。

```powershell
.\.venv\Scripts\python.exe evaluate_domain_valid.py `
  --model runs\mixed-v1\final `
  --data data\domain-valid.jsonl `
  --show-misses `
  --json
```

exact matchは、生成文字列が期待値と1文字単位で完全一致した件数である。厳しい指標なので、
不一致例も確認し、表記揺れなのか、本当に変換できていないのかを分けて読む。

今回の結果:

| モデル | exact match |
|---|---:|
| 学習前 `ku-nlp/gpt2-small-japanese-char` | 0/60（0%） |
| `mixed-v1` | **50/60（83.3%）** |

60件はtrainから除外されているので、この改善はtrain行の単純な丸暗記だけを測った値ではない。
一方、同じドメイン原本から分割した検証データなので、まったく別分野への汎化性能を表すものでもない。

## 10. Hugging Faceへprivate保存する

学習済みHF形式は、`tanabe1478/gyaim-lm-small` のprivateモデルリポジトリへ置く。
このWindows環境は作業開始時にHugging Faceへ未ログインだったため、OAuth device flowで
認証した。tokenをコマンド履歴、ログ、Gitへ書かない。

```powershell
.\.venv\Scripts\hf.exe auth login
.\.venv\Scripts\hf.exe auth whoami
```

評価結果をmodel cardの `README.md` に記録してから、privateリポジトリを作成・アップロードする。

```powershell
.\.venv\Scripts\hf.exe repos create tanabe1478/gyaim-lm-small --private --exist-ok
$env:HF_XET_HIGH_PERFORMANCE = '1'
.\.venv\Scripts\hf.exe upload `
  tanabe1478/gyaim-lm-small `
  runs\mixed-v1\final `
  .

.\.venv\Scripts\hf.exe upload `
  tanabe1478/gyaim-lm-small `
  runs\mixed-v1\gyaim-lm-small-v1-Q5_K_M.gguf `
  gyaim-lm-small-v1-Q5_K_M.gguf
```

アップロード対象は原則として `final/` のモデル、tokenizer、model cardと配布用Q5_K_Mだけにする。
F16 GGUFはQ5_K_Mの再生成用ローカル成果物で、HF形式の元重みと内容が重複するため通常は省く。
`data/` やdogfoodログ、途中checkpointを同じリポジトリへ誤って含めない。

2026-08-16の実行結果:

- private repository: [tanabe1478/gyaim-lm-small](https://huggingface.co/tanabe1478/gyaim-lm-small)
- `private: true` をHub APIで再確認
- HF model、tokenizer、model card、Q5_K_Mの計8ファイルを保存
- HubがHF重み90,450,432 parameters、GGUF 73,871,776 bytesとして認識
- 使用ストレージ435,693,681 bytes
- `data/`、domain原本、checkpoint、F16 GGUFはアップロードしていない

## 11. GGUF化とアプリ実測

HF形式で品質が確認できた後にGGUFへ変換し、Q5_K_Mへ量子化する。量子化はモデルサイズと
実行速度を改善する一方、精度を少し落とす可能性があるため、HF版との比較が必要。

このモデルのtokenizerは `gpt2-small-japanese-char` というpre-tokenizer情報を持つ。
素のllama.cpp converter/runtimeでは未知として拒否される可能性があるので、PR #93のM7-3に従い、
SwiftyGyaim同梱フォークの対応状況と `tokenizer.ggml.pre` を検証してからbundleを差し替える。

### 11.1 converterを学習環境から分離する

SwiftyGyaimが利用する`azooKey/llama.cpp`フォークには、converterとruntimeの両方に
`gpt2-small-japanese-char`対応がある。確認時のcommitは`88b97a4`。

converterはTransformers 4系、学習環境はTransformers 5.15を使うため、同じvenvへ混ぜない。

```powershell
git clone --depth 1 `
  https://github.com/azooKey/llama.cpp.git `
  runs\tools\llama.cpp

py -3.12 -m venv runs\tools\.venv-convert
.\runs\tools\.venv-convert\Scripts\python.exe -m pip install --upgrade pip wheel
.\runs\tools\.venv-convert\Scripts\python.exe -m pip install `
  -r runs\tools\llama.cpp\requirements\requirements-convert_hf_to_gguf.txt
```

### 11.2 Windows用quantizeツールをビルドする

この機体にはVisual Studio 2022 Build Toolsと同梱CMakeが入っている。

```powershell
$cmake = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'

& $cmake `
  -S runs\tools\llama.cpp `
  -B runs\tools\llama.cpp\build-windows `
  -G 'Visual Studio 17 2022' `
  -A x64 `
  -DLLAMA_CURL=OFF `
  -DGGML_NATIVE=OFF

& $cmake `
  --build runs\tools\llama.cpp\build-windows `
  --config Release `
  --target llama-quantize `
  --parallel 8
```

生成物は`runs/tools/llama.cpp/build-windows/bin/Release/llama-quantize.exe`。

### 11.3 HFからF16 GGUF、Q5_K_Mへ変換する

Transformers 5が保存するGPT-2設定は文脈長を`n_positions`として持つ一方、確認時点の
azooKey converterは旧名`n_ctx`を読む。`train_zenz.py`は、同じ値を両方の名前で保存して
この互換差を吸収する。既存の`final/config.json`で`n_ctx`がない場合だけ、次を一度実行する。

```powershell
.\.venv\Scripts\python.exe -c `
  "from pathlib import Path; from train_zenz import add_legacy_gpt2_context_alias; add_legacy_gpt2_context_alias(Path(r'runs/mixed-v1/final'))"
```

```powershell
.\runs\tools\.venv-convert\Scripts\python.exe `
  runs\tools\llama.cpp\convert_hf_to_gguf.py `
  runs\mixed-v1\final `
  --outfile runs\mixed-v1\gyaim-lm-small-v1-f16.gguf `
  --outtype f16 `
  --model-name gyaim-lm-small-v1

.\runs\tools\llama.cpp\build-windows\bin\Release\llama-quantize.exe `
  runs\mixed-v1\gyaim-lm-small-v1-f16.gguf `
  runs\mixed-v1\gyaim-lm-small-v1-Q5_K_M.gguf `
  Q5_K_M
```

converterログまたはGGUF metadata dumpで、`tokenizer.ggml.pre` が
`gpt2-small-japanese-char` になっていることを必ず確認する。F16 GGUFは変換元として残し、
アプリ同梱候補にはQ5_K_Mを使う。

今回の生成結果:

| ファイル | サイズ | SHA-256 |
|---|---:|---|
| `gyaim-lm-small-v1-f16.gguf` | 183.04 MiB | `D3A5BAC50A1D69ACB1810E93AA7ED3CD5ACB0EC66AC829E188DE947AD1C2AD09` |
| `gyaim-lm-small-v1-Q5_K_M.gguf` | 70.26 MiB | `5F141ED09C41A918FF8D8653443BBC1D92DE1C274555BE1E3F0742A2E0C8D992` |

Q5_K_MはフォークのWindows CLIでロードでき、95.06M parameters、GGUF V3、
`tokenizer.ggml.pre=gpt2-small-japanese-char` を確認した。WindowsではSwift/macOSアプリを
実行できないため、量子化による候補順位差、app bundle差し替え、レイテンシはMacで行う。

## 12. よく出る警告と対処

### `Permission denied (publickey)`

GitHub SSH鍵がWindowsに未設定。HTTPS URLでcloneするか、別途SSH鍵を登録する。

### Hugging Faceのsymlink警告

WindowsのDeveloper Modeが無効だと、Hugging Face cacheがsymlinkを使えず容量効率が落ちる。
学習自体は継続できる。繰り返し多数のモデルを扱う場合はDeveloper Modeを検討する。

### unauthenticated requests警告

公開モデル・公開データは未ログインでも取得できる。大量・頻回アクセスではrate limitを避けるため
Hugging Face tokenを設定する。tokenをログやリポジトリへ書かない。

### `nvidia-smi` が見つからない

AMD GPUなので正常。GPU認識は `torch.cuda.is_available()` と
`torch.cuda.get_device_name(0)`、実際のGPU演算で確認する。

### `device=cuda` と表示される

ROCm版PyTorchがCUDA互換API名を使っているため正常。`torch.version.hip` が7.2系ならAMD経路である。

### lossがNaNになる

FP16の数値範囲を超えた可能性がある。直前checkpointからFP32で再開する、learning rateを下げる、
またはgradient clippingや別の混合精度設定を検討する。今回の500 stepベンチでは発生していない。

## 13. プライバシーとGit管理

- `data/domain.jsonl` はredaction済みだが、ユーザー語彙を含むため取り扱いに注意する
- それ以外の `data/*`、`data-bench/`、`runs/`、`.venv/` はGit管理外
- ドメインデータを外部GPUやpublicモデルリポジトリへ送らない
- 学習成果物をHugging Faceへ置く場合はprivateリポジトリにする
- commit前は必ず `git status --short` で巨大なJSONLやcheckpointが入っていないことを確認する

## 14. このWindows引き継ぎで変更したもの

- PRブランチをHTTPSでclone
- ネイティブWindows用ROCm 7.2.1 / PyTorch 2.9.1環境を `.venv` に構築
- GPU検出と実GPU行列積を確認
- 30,000件のベンチデータを生成
- FP32とFP16を比較し、FP16 501 stepで226 examples/sを確認
- `train_zenz.py` に明示的な `--fp16` オプションを追加
- 最新の本番データ1,013,720件を再生成
- FP16のmixed-v1学習を71分32秒で完了（236.2 examples/s）
- valid loss 0.1167、perplexity 1.12を確認
- `evaluate_domain_valid.py` を追加し、学習前0/60から学習後50/60への改善を確認
- fixture 122件で84/122を確認（現行small基準80/122）
- Transformers 5とconverterの`n_positions` / `n_ctx`互換差を学習スクリプトで吸収
- F16 GGUFとQ5_K_M GGUFを生成し、フォークのWindows CLIでロードを確認
- HFモデル・tokenizer・model card・Q5_K_MをHugging Faceへprivateアップロード

残作業は、Mac上でのアプリbundle差し替え・量子化後の候補順位比較・レイテンシ計測である。
