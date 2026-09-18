# Specs — 領域仕様書

SwiftyGyaim の領域別仕様書。CLAUDE.md/AGENTS.md の「Required Spec Workflow」と pi-context-workflow 拡張（`.pi/context-workflow.json`）の両方が、このディレクトリの `> Trigger:` 行を使って「編集前に読むべき spec」を決定する。

## ルール

1. ソースファイルを編集する前に、対応する領域 spec を読む
2. 振る舞い・制約・フロー・保存形式・セキュリティ・テスト観点を変えたら spec を同じコミットで更新する
3. ソースファイルごとに機械的に spec を作らない — 1つの spec が複数ファイルをカバーしてよい
4. ローカルな型・関数の契約はソースのドキュメントコメントに書く
5. バグ修正時は `bugs/BUG-*.md` に詳細を追加し、`bug-memory.md` の索引を更新する
6. 各 spec は `> Trigger:` と `> Last updated:` ヘッダを維持する

## Trigger の意味

`Trigger:` は「このファイルを触るときに読むべき領域 spec」の宣言であり、spec とファイルの 1:1 対応ではない。マッチはファイル名またはパス断片で行われる。

## 現在の spec 一覧

| Spec | Trigger | 内容 |
|------|---------|------|
| `input-flow.md` | GyaimController.swift, GyaimController+FastContextRerank.swift | キー入力→変換→確定フロー、routeEvent設計 |
| `dictionary-system.md` | WordSearch.swift, ConnectionDict.swift | 3階層辞書、学習、ホットリロード |
| `candidate-window.md` | CandidateWindow.swift, PreferencesWindow.swift | 候補表示モード、NSPanel制約 |
| `google-transliterate.md` | GoogleTransliterate.swift | Google API連携、非同期処理、stale guard |
| `imk-constraints.md` | GyaimController.swift, AppDelegate.swift, main.swift | InputMethodKit固有の制約と回避策 |
| `settings.md` | GyaimSettings.swift（設定キーを追加・変更する全ファイル） | 設定ストア、全キー一覧と既定値、ADR-027 |
| `ai-rerank.md` | AIReranker*.swift, ZenzRuntime*.swift 等 | ヒューリスティック/モデル rerank、スコア統合 |
| `zenz-model-tuning.md` | Zenz モデル・プロンプト調整 | モデル選定とチューニングの記録（Draft） |
| `project-setup.md` | project.yml, Scripts/*.sh, workflows 等 | ビルド・テスト・配布のセットアップ |
| `bug-memory.md` | 全ファイル（デバッグ時） | バグ索引と運用ガイド（詳細は `bugs/`） |
| `bugs/BUG-*.md` | 個別バグ | 再利用可能なバグ知識 |
