# AGENTS.md

This file provides guidance to pi and other coding agents working in this repository.

## CRITICAL: PR作成ルール

PRは必ず `--repo tanabe1478/SwiftyGyaim` を指定して作成すること。`--repo` を省略すると `gh` がフォーク元（masui/GyaimMotion）に向けてPRを作成してしまう。

```bash
# 正しい
gh pr create --repo tanabe1478/SwiftyGyaim --base master --head <branch> ...

# 禁止（--repo省略）
gh pr create --title ... --body ...
```

## Project Overview

- macOS用 日本語IME `SwiftyGyaim`
- 実装: Swift + InputMethodKit
- 開発単位ディレクトリ: `GyaimSwift/`
- プロジェクト管理: XcodeGen (`project.yml`)

## Build & Test

作業ディレクトリは `GyaimSwift/`。

```bash
xcodegen generate
xcodebuild -project Gyaim.xcodeproj -scheme Gyaim -configuration Debug -derivedDataPath .build build
./Scripts/run-unit-tests.sh
```

E2Eテスト:

```bash
xcodebuild -project Gyaim.xcodeproj -scheme GyaimE2ETests -derivedDataPath .build test
```

## Architecture Snapshot

- `Sources/Gyaim/GyaimController.swift`: IME入力処理の中心
- `Sources/Gyaim/WordSearch.swift` + `ConnectionDict.swift`: 3層辞書
- `Sources/Gyaim/CandidateWindow.swift`: 候補UI
- `Sources/Gyaim/PreferencesWindow.swift`: 設定UI
- `Sources/Gyaim/GoogleTransliterate.swift`: Google候補補完

辞書優先度:
1. `~/.gyaim/studydict.txt`
2. `~/.gyaim/localdict.txt`
3. `resources/dict.txt`

## InputMethodKit Constraints

- IMEは `LSBackgroundOnly`
- `NSApp.unhide(nil)` は使わない。`orderFront(nil)` のみ
- 候補ウィンドウは `.nonactivatingPanel` 必須
- `deactivateServer(_:)` では `sender as? IMKTextInput` だけに依存せず `self.client()` フォールバックを使う
- ターミナルでは Ctrl 系ショートカットが届かない場合がある

## Required Spec Workflow

`.swift` を編集する前に、対象に応じて `docs/specs/` の関連specを必ず読むこと。

| Spec | Trigger |
|------|---------|
| `docs/specs/input-flow.md` | `GyaimController.swift` |
| `docs/specs/dictionary-system.md` | `WordSearch.swift`, `ConnectionDict.swift` |
| `docs/specs/candidate-window.md` | `CandidateWindow.swift`, `PreferencesWindow.swift` |
| `docs/specs/google-transliterate.md` | `GoogleTransliterate.swift` |
| `docs/specs/imk-constraints.md` | `GyaimController.swift`, `AppDelegate.swift`, `main.swift` |
| `docs/specs/bug-memory.md` | バグ調査・修正時は常に参照 |

必須ルール:
1. `.swift` 編集前に対応specを読む
2. バグ修正後は `docs/specs/bug-memory.md` に追記
3. 動作仕様を変えたら対応specを同じコミットで更新
4. コミット前に spec の `Last updated` を確認

## Testing Notes

- ユニットテストは `GyaimSwift/Tests/GyaimTests/`
- E2Eは `GyaimSwift/Tests/E2ETests/`
- UI/入力分岐は既存テストが厚いので、修正時は関連テスト追加を優先する

## Related Agent Files

- `CLAUDE.md`: Claude Code向けの詳細版ガイド
- `.claude/hooks/`: Claude用hook
- `docs/specs/`: 領域別の仕様
- `docs/adr/`: 設計判断の履歴

この `AGENTS.md` は、Claude向け設定がある環境でも pi など別のエージェントが同じ運用ルールを参照できるように置いている。
