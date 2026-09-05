---
language:
  - ja
license: cc-by-sa-4.0
library_name: transformers
pipeline_tag: text-generation
base_model: ku-nlp/gpt2-small-japanese-char
datasets:
  - Miwa-Keita/zenz-v2.5-dataset
tags:
  - japanese
  - ime
  - kana-kanji-conversion
  - gpt2
  - zenz
---

# gyaim-lm-small-public-v1

SwiftyGyaimのかな漢字変換候補を左文脈付きで評価するための、日本語GPT-2
条件付き言語モデルです。汎用チャットモデルではありません。

## 個人データを使わない方針

この版の学習にはSwiftyGyaimの利用ログ、学習辞書、ユーザー辞書、dogfoodデータを
使用していません。`Miwa-Keita/zenz-v2.5-dataset`の次の公開2ファイルだけを使用しました。

| source | examples |
|---|---:|
| `train_wikipedia.jsonl` | 17,493,369 |
| `train_llm-jp-corpus-v3.jsonl` | 171,487,973 |
| total | 188,981,342 |

## モデル

- architecture: GPT-2 decoder-only causal language model
- base model: `ku-nlp/gpt2-small-japanese-char`
- parameters（Transformers、tied embeddings）: 90,450,432
- vocabulary: 6,000
- context length: 1,024
- intended task: Japanese kana-kanji conversion candidate scoring

入力形式はZenzのprivate-use control tagを使います。

```text
\uEE02<left_context>\uEE00<input_katakana>\uEE01<output></s>
```

学習時はprompt部分をmaskし、`output`と終端tokenだけでlossを計算しました。

## 学習設定

- method: full-parameter supervised fine-tuning（LoRAではありません）
- sequence length: 192
- batch size: 32
- gradient accumulation: 1
- learning rate: 1e-4、linear decay
- precision: FP16 mixed precision
- seed: 42
- planned optimizer steps: 5,905,667
- completed optimizer steps: 5,905,651
- hardware: AMD Radeon RX 9070 XT 16GB / native Windows / PyTorch ROCm 7.2.1

複数回の安全停止・再開に伴うTrainerの先読み境界により、最大510 examples
（全188,981,342件の約0.00027%）はoptimizer更新に使われていません。

## 評価

| metric | result |
|---|---:|
| public validation loss（5,000件） | 0.05007 |
| public validation perplexity | 1.05 |
| SwiftyGyaim public-general fixture top-1 | 74/104（71.15%） |

public-general fixtureはプロジェクト内の回帰評価であり、標準化された日本語IME
ベンチマークではありません。122件の元fixtureから`user-dict`、`dogfood-regression`、
`preference`タグの18件をモデルへ渡す前に除外しました。

Q5_K_M GGUFは対応するazooKey/llama.cppフォークでロード確認済みです。
量子化後の104件ランキング比較とmacOSアプリ内の品質・レイテンシ評価は未実施です。

## ファイル

- `model.safetensors`: Transformers用F32重み
- `gyaim-lm-small-public-v1-Q5_K_M.gguf`: SwiftyGyaim同梱候補

GGUFは`tokenizer.ggml.pre=gpt2-small-japanese-char`を扱える
azooKey/llama.cppフォーク向けです。

## 制限と注意

- かな漢字変換候補の条件付きscoringに特化しており、会話・質問応答用ではありません。
- 公開Webコーパス由来の偏り、不正確な内容、不適切な表現を継承する可能性があります。
- 読みは自動生成され、読み揺れも加えられているため、読み推定データとしての利用には
  適しません。
- 実際にIMEへ同梱する前に、GGUF版の候補順位とmacOS上のレイテンシを確認してください。

## ライセンスと出典

この派生モデルはbase modelに合わせてCC BY-SA 4.0で提供します。

- base model: [`ku-nlp/gpt2-small-japanese-char`](https://huggingface.co/ku-nlp/gpt2-small-japanese-char) — CC BY-SA 4.0
- training dataset: [`Miwa-Keita/zenz-v2.5-dataset`](https://huggingface.co/datasets/Miwa-Keita/zenz-v2.5-dataset)
  - Wikipedia subset — CC BY-SA 4.0
  - llm-jp Common Crawl subset — ODC-BYおよびCommon Crawl Terms of Use
- application: [`tanabe1478/SwiftyGyaim`](https://github.com/tanabe1478/SwiftyGyaim)

再配布・利用時には各リンク先の最新ライセンスと利用条件も確認してください。
