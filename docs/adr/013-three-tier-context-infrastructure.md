# ADR-013: 3階層コンテキスト基盤の導入

## Status

Accepted

## Decision

論文 "Codified Context: Infrastructure for AI Agents in a Complex Codebase" (arXiv:2602.20478) の3階層ドキュメントシステムをSwiftyGyaimの開発フローに導入する。

## Context

AIコーディングにおいて、セッション間で記憶が共有されないため、プロジェクトの規約や過去のミスを繰り返す問題がある。論文では、ドキュメントを3階層に整理し、AIが状況に応じて参照する仕組みで、10万行規模でも高品質なコード生成を実現した。

SwiftyGyaimは3,950行と小規模だが、InputMethodKitの特殊な制約やIME固有のパターンが多く、セッションごとにコンテキストを失うコストが大きい。

## Consideration

### 現状の資産と論文の3階層のマッピング

| 論文の階層 | 定義 | SwiftyGyaim現状 | 対応 |
|-----------|------|----------------|------|
| **Tier 1 (常時読込)** | 基本ルール、やってはいけないミス | CLAUDE.md | 既にある。強化する |
| **Tier 2 (領域トリガー)** | 特化エージェント仕様書 | なし | 新設: `docs/specs/` |
| **Tier 3 (オンデマンド検索)** | 詳細仕様書 | docs/codemaps/, docs/adr/ | 既にある。索引を整備 |

### 論文で特に重要な知見

1. **Specの鮮度が命** — 古い情報は誤ったコードを生む。週1-2時間のメンテナンスが必要
2. **バグメモリ** — 過去のバグ修正記録をAIが引き出せることで、人間が特定できない問題を発見
3. **人間の役割シフト** — コードを書くことから「AIが迷わない知識基盤」の設計・管理へ

## Consequences

### ディレクトリ構成

```
CLAUDE.md                          ← Tier 1: 常時読込
docs/
├── specs/                         ← Tier 2: 領域特化仕様書（新設）
│   ├── input-flow.md              # キー入力→変換→確定フロー
│   ├── dictionary-system.md       # 3階層辞書（search/study/register）
│   ├── candidate-window.md        # 候補表示（list/classic, positioning）
│   ├── google-transliterate.md    # Google API連携（async, stale guard）
│   ├── imk-constraints.md         # InputMethodKit制約集
│   └── bug-memory.md              # 過去のバグと修正パターン
└── adr/                           ← Tier 3: 設計判断の記録
    └── *.md
```

### 各階層の役割

**Tier 1: CLAUDE.md（常時読込）**
- PR作成ルール、ビルドコマンド、テスト実行方法
- Key Constraints（IMEの重要な制約）
- **新規追加**: よくあるミスのリスト（bug-memoryからの昇格）
- **新規追加**: specs/への索引（どの領域を触るときにどのspecを読むか）

**Tier 2: docs/specs/（領域トリガー）**
- 特定ファイルを編集する際に参照すべき仕様書
- トリガー条件をファイル冒頭に明記（例: `Trigger: GyaimController.swift, WordSearch.swift`）
- 過去のバグパターンと回避策を含む

**Tier 3: docs/codemaps/, docs/adr/（オンデマンド）**
- コードマップ: ファイル間の依存関係、データフロー
- ADR: 設計判断の経緯と理由
- 必要なときだけ検索して参照

### メンテナンスフロー

週次（目安30分、小規模プロジェクトのため）:
1. 直近のgit logからspec更新が必要な変更を特定
2. 影響するspecを更新
3. 新たに発見したバグパターンをbug-memory.mdに追記
4. 頻出パターンはCLAUDE.mdに昇格

## References

- [arXiv:2602.20478 - Codified Context: Infrastructure for AI Agents in a Complex Codebase](https://arxiv.org/pdf/2602.20478)
- [Algomatic AILab による解説](https://x.com/Algomatic_AILab/status/2032028482520432762)
