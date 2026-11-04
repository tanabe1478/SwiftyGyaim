# model-training: gyaim-lm の学習

Issue #125の次期学習は[ISSUE-125.md](ISSUE-125.md)を参照。
文脈変種のあるdomainデータには、固定評価を除外しペア単位で分割する
`prepare_context_training.py`を使う。

SwiftyGyaim専用のかな漢字変換モデル **gyaim-lm** を学習するためのツール群。

- gyaim-lm は zenz ではない: 元モデル `ku-nlp/gpt2-small-japanese-char` から学習する自前モデル
- ただし**プロンプト形式は zenz-v3 互換**（文脈前置タグ・output-onlyロス）。SwiftyGyaimの
  ZenzPrompt / LlamaZenzContext ランタイムをそのまま使うため
- 命名規則: `gyaim-lm-<size>-v<N>`（例: gyaim-lm-small-v1）。学習runは `runs/<データ構成>-v<N>`
- zenz比較用ツール（compare-hf-gguf.py）も本ディレクトリに同居する

背景と経緯は `docs/specs/zenz-model-tuning.md` と `docs/zenz-model-tuning-tasklist.md`（M7）を参照。
Windowsでの実測を含む初心者向け手順は
[`docs/gyaim-lm-windows-training-guide.md`](../../../docs/gyaim-lm-windows-training-guide.md) を参照。

## 全体像

```
build_sft_dataset.py   ~/.gyaim/archive + gyaim.log → ドメインJSONL（選んだ候補 + かな確定。打ち直した誤確定を除き、
                       文脈は実行時と同じ末尾 20 文字と、その 10 / 5 / 0 文字の変種。issue #125）
prepare_dataset.py     zenz-v2.5-dataset(公開1.9億ペア)をストリーミングサンプル + ドメイン混合
train_zenz.py          HF Trainerで学習（MPS/CUDA(ROCm含む)/CPU自動選択、--resume対応）
compare-hf-gguf.py     eval fixtureでHF/GGUFスコアリング品質を比較（タグ除外対応）
```

公開データから再生成するsplitとcheckpointは `data/` と `runs/` でgitignoreする。
`data/` は全部 gitignore する。ドメインデータ（`domain.jsonl` / `domain-valid.jsonl` / `rerank-valid.jsonl`）は redaction 済みでもユーザーの入力文を含むため、公開リポジトリでは追跡しない（2026-11-03 に追跡をやめた。それ以前の履歴には残っている）。学習マシンへは直接コピーするか、private の Hugging Face リポジトリ経由で渡す。


### ドメインデータの受け渡し（private Hugging Face）

```bash
hf auth login                      # 初回のみ。トークンは write 権限
python3 push_domain_data.py        # ~/.gyaim/eval/domain-2026-11.jsonl と data/*-valid.jsonl を
                                   # private dataset repo tanabe1478/gyaim-domain-data に上げる
# 学習マシン側
hf download tanabe1478/gyaim-domain-data --repo-type dataset --local-dir data/
```

`push_domain_data.py` は repo が private でなければ中止する。`--dry-run` で対象だけ確認できる。

## テスト

`test_compare_hf_gguf.py` は標準ライブラリのみで動き、`Scripts/run-unit-tests.sh`（CI）で常に実行される。`test_train_zenz.py` は torch/transformers が必要なので、同スクリプトは `.venv` にそれらが入っている場合だけ実行し、無ければ skip を表示する。手動実行:

```bash
./.venv/bin/python -m unittest test_train_zenz.py
```

## リポジトリ方針

学習コードは**本リポジトリ内**（このディレクトリ）で管理する。理由:

- `build_sft_dataset.py` が `Sources/Gyaim/RomaKana.swift` のルール表を直接パースする（IMEと変換規則を同期）
- 評価が `Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl` を共有する
- 学習マシン側は本リポジトリをcloneするだけで全部動く

将来モデル・レシピを一般公開する場合に、公開用リポジトリへ切り出しを検討する。

## モデルの置き場所

- **学習成果物（HF重み・checkpoint・GGUF）は Hugging Face の private リポジトリ（例: `tanabe1478/gyaim-lm-small`）に置く**
  （無料・LFS込み・`huggingface_hub`で機械アクセス可能）。
  ドメインデータ（ユーザーのログ）を学習に使ったモデルは**ユーザーの語彙を含むため必ずprivate**にする
- アプリ同梱GGUFは従来どおりapp bundle（`Resources/Models/`）。ただしモデル更新のたびに
  70MB級バイナリをgit履歴に積むとリポジトリが肥大するため、更新頻度が上がったら
  「ビルド時にHF/GitHub Releaseから取得」方式への切替を検討する
- ライセンス: 元モデルとzenz-v2.5-datasetはCC-BY-SA 4.0（一部ODC-BY）。
  **モデルを公開配布する場合は継承義務が発生**する。private運用なら問題なし

## 環境構築

### macOS (Apple Silicon)

```bash
mise use -g python@3.12
cd GyaimSwift/Tools/model-training
mise exec python@3.12 -- python3 -m venv .venv
./.venv/bin/pip install torch transformers accelerate datasets llama-cpp-python
```

### Windows + Radeon RX 9070 XT（ネイティブWindows + ROCm、推奨）

RX 9070 XT（gfx1201）は、Windows 11 / Python 3.12 / PyTorch 2.9.1 + ROCm 7.2.1で
公式サポートされている。AMD Software 26.2.2以降へ更新してから、プロジェクト内venvへ
AMD公式wheelを入れる。完全なコマンド、GPU検証、実測値は初心者向け手順書を参照。

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip wheel
# ROCm SDKとROCm版torchはAMD公式手順の7.2.1 wheelを使用する
.\.venv\Scripts\python.exe -m pip install transformers accelerate datasets
.\.venv\Scripts\python.exe -c "import torch; print(torch.__version__, torch.version.hip, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

`train_zenz.py` ではROCmも `device=cuda` と表示される。RX 9070 XTでは `--fp16` が重要で、
500 step実測はFP32約27 examples/sに対し、FP16 **226 examples/s**だった。

## Windows側でゼロから始めるチェックリスト

Macに接続せず、Windowsマシン単体で始める場合の完全な手順。

1. Windows 11 + Python 3.12とAMDドライバ（上記「環境構築」参照）
2. リポジトリ取得:
   ```powershell
   git clone https://github.com/tanabe1478/SwiftyGyaim.git
   cd SwiftyGyaim
   git checkout feature/zenz-specialized-training   # PR #93マージ前の場合
   cd GyaimSwift/Tools/model-training
   ```
3. venv + ネイティブWindows版ROCm/PyTorch
4. **ベンチ実行**（下記）→ examples/s を確認し判断表と照合
5. データ:
   - 公開データはseed固定で**Windows側だけで再現可能**（`prepare_dataset.py` を同じ引数で実行すれば
     Macと同一のtrain/validができる）
   - `data/domain.jsonl`（ユーザーのログ由来）は**リポジトリに含めない**。Mac側で `build_sft_dataset.py` を
     再実行し（既定の出力先は `~/.gyaim/eval/` など repo 外を推奨）、敬称・組織語・人名を `--exclude-regex` で
     除外してから、学習マシンへ直接コピーするか private の Hugging Face リポジトリに置く
6. 学習実行（下記「学習の実行と引き継ぎ」）。Macで学習が走っている場合は、Windows側の
   ベンチが十分速いことを確認してからMac側を止める（両方走らせても害はないが電力の無駄）

## ベンチマーク（採用判断は必ず実測で）

新しい学習マシンでは500ステップの実測をしてから採用を決める。

```powershell
.\.venv\Scripts\python.exe prepare_dataset.py --wikipedia 20000 --llm-jp 10000 --valid 100 --output data-bench
.\.venv\Scripts\python.exe train_zenz.py --train data-bench\train.jsonl --output runs\bench `
  --epochs 0.535 --batch-size 32 --max-length 192 --fp16
# 進捗バーの it/s × batch-size = examples/s。500ステップ見たらCtrl+Cで打ち切ってよい
```

判断の目安（1.9億ペア1epochの所要 = 190,000,000 ÷ examples/s ÷ 86,400 日）:

| examples/s | 100万ペア | 1.9億フル | 位置づけ |
|---|---|---|---|
| ~15（M5 MPS実測） | 18〜20h | 約140日 | 中規模実験・週次再学習 |
| ~50 | 5.5h | 約44日 | 中規模は快適、フルは要相談 |
| 226（9070 XT FP16実測） | 約75分 | 約9.7日 | フルもローカル圏内 |
| H100 1GPU（参考） | 分単位 | 数時間（本家実績、約1,008円/h） | 確定レシピの本番1回用 |

## 学習の実行と引き継ぎ

```bash
# 本番（100万ペア例）
nohup ./.venv/bin/python3 train_zenz.py --train data/train.jsonl --valid data/valid.jsonl \
  --output runs/mixed-v1 --epochs 1 --batch-size 32 --max-length 192 --lr 1e-4 \
  --save-steps 4000 > runs/train.log 2>&1 &

# 中断からの再開（checkpointは4,000ステップごと、同一--outputを指定）
./.venv/bin/python3 train_zenz.py --train data/train.jsonl --valid data/valid.jsonl \
  --output runs/mixed-v1 --resume ...
```

- loss推移はcheckpoint内の `trainer_state.json`（`log_history`）で確認できる
- **マシンを乗り換える場合**: 途中checkpointの移送より、速いマシンでゼロからやり直す方が
  速くて確実（デバイス間のRNG状態互換を踏まない）。checkpoint自体は可搬なので、
  どうしても続きからやる場合は `runs/<name>/checkpoint-*` を丸ごとコピーして `--resume`
- スリープ抑止: macOSは `caffeinate -s`、WSL2はWindows側の電源設定で

## 評価（学習後）

### 実験用の文脈候補蒸留

`cache_context_teacher.py` は固定評価・従来holdoutを除外し、読み単位で分割した
候補ペアに対して、教師モデルの文脈あり平均logprob差をFP32で保存する。
`train_context_preference.py --objective context_distill --teacher-scores <cache>` は
その差から得た2候補間の確率を学習し、文脈なしのスコアは学習前の生徒モデルへ
MSEで固定する（`--anchor 0 --prior-preservation 10`、学習は`--precision fp32`）。
キャッシュの元データSHA256・全ペアの対応・有限値を検証する。教師の文脈なし分布は
転写しない。全語彙のtoken KL蒸留ではなく、候補ペアの蒸留である。
通常のpair学習が既定のまま。蒸留と`--prior-replay`は併用不可。
`--dropout 0`を指定するとGPT2の学習時dropoutを無効にできる。
省略時は元モデルの設定を維持する。値は0以上1未満で、manifestとモデルconfigに保存する。
`--deterministic-prior`は`context_distill`専用の比較設定で、文脈ありのdropoutは残し、
文脈なしの保持計算だけevalモードで行う。勾配は保持し、forward後に各moduleの状態を復元する。
既定は無効。manifestの`deterministicPrior`に記録し、gradient checkpointingとは併用不可。
これはeval参照スコアに対する保持損失への確率的変動を除く比較実験用の設定である。
このモードの追加自体は精度改善の証拠ではない。独立評価・native評価は別途必要。

```bash
# 公開可能な一般fixtureだけでスコアリング品質を測る
./.venv/bin/python3 compare-hf-gguf.py \
  --backend hf \
  --hf-model runs/zenz-v2.5-full/final \
  --exclude-tags user-dict dogfood-regression preference \
  --output runs/zenz-v2.5-full/eval/public-general-hf.json

# ドメイン検証（ユーザー語彙60件のexact match）
./.venv/bin/python3 evaluate_domain_valid.py \
  --model runs/mixed-v1/final --data data/domain-valid.jsonl --json
```

2026-09-01 Windows実測: 公開データ限定`zenz-v2.5-full`はvalid loss 0.05007、
public-general fixture 74/104（71.15%）。Q5_K_M GGUFは73,871,808 bytesで、
対応フォークのCLIからロードできる。詳細とWindows用コマンドは
`docs/gyaim-lm-windows-training-guide.md`を参照。旧`mixed-v1`とdomain評価は履歴としてのみ残す。

GGUF化: 素のllama.cppは pre-tokenizer `gpt2-small-japanese-char` を知らないため
（M4-2の知見）、変換時に `tokenizer.ggml.pre` の扱いを検証すること。同梱llama.cppフォークは対応済み。
