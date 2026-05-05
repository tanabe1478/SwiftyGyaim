# SwiftyGyaim 内部設計ドキュメント

このディレクトリは、SwiftyGyaim のソースコードを理解するための内部向けドキュメントです。実装を読む入口として、全体像、macOS IME API、主要機能ごとの処理フローをまとめています。

## 読む順番

1. [全体アーキテクチャ](architecture.md)
2. [Swift / InputMethodKit で作る IME の概要](ime-api.md)
3. [入力・変換・確定フロー](input-flow.md)
4. [辞書・学習システム](dictionary-system.md)
5. [候補ウィンドウとUI](candidate-window-and-ui.md)
6. [機能別実装ガイド](feature-guide.md)
7. [テスト・ビルド・運用](testing-and-operations.md)

## ソースコードの主な場所

```text
GyaimSwift/
├── project.yml                 # XcodeGen定義
├── Resources/                  # Info.plist, dict.txt, アイコン等
├── Sources/Gyaim/              # 本体実装
│   ├── main.swift              # IMKServer起動
│   ├── AppDelegate.swift       # アプリライフサイクル
│   ├── GyaimController.swift   # IME入力処理の中心
│   ├── WordSearch.swift        # 辞書検索・学習
│   ├── ConnectionDict.swift    # 連接辞書
│   ├── RomaKana.swift          # ローマ字かな変換
│   ├── CandidateWindow.swift   # 候補ウィンドウ
│   ├── PreferencesWindow.swift # 設定画面
│   ├── DictEditorWindow.swift  # ユーザー辞書エディタ
│   └── ...
└── Tests/
    ├── GyaimTests/             # ユニットテスト
    └── E2ETests/               # E2Eテスト
```

## 関連ドキュメント

- `CLAUDE.md` / `AGENTS.md`: agent 向け運用ルール
- `docs/specs/`: 実装と同期する領域別仕様
- `docs/adr/`: 設計判断の記録

この `docs/internal/` は、上記よりも「初めて読む人が理解する」ことを重視した解説です。
