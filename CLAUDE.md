# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Shared-agent note: `AGENTS.md` contains a pi/agent-compatible summary of the same repository rules so non-Claude agents can recognize the project conventions too.

## CRITICAL: PR作成ルール

PRは必ず `--repo tanabe1478/SwiftyGyaim` を指定して作成すること。`--repo` を省略すると `gh` がフォーク元（masui/GyaimMotion）に向けてPRを作成してしまう。

```bash
# 正しい
gh pr create --repo tanabe1478/SwiftyGyaim --base master --head <branch> ...

# 禁止（--repo省略）
gh pr create --title ... --body ...
```

## Project Overview

Gyaim is a Japanese Input Method Editor (IME) for macOS. Originally created by Toshiyuki Masui (2011) in RubyMotion, migrated to Swift (GyaimSwift/).

- **App identifier**: `com.pitecan.inputmethod.SwiftyGyaim`
- **Language**: Swift
- **Frameworks**: InputMethodKit, Security
- **Project management**: XcodeGen (project.yml)

## Build & Development Commands

```bash
# Generate Xcode project
xcodegen generate

# Build（インストール用は必ずRelease。Debugは辞書検索が3〜4倍遅く体感退行する）
xcodebuild -project Gyaim.xcodeproj -scheme Gyaim -configuration Release -derivedDataPath .build build

# Install（開発イテレーション用: per-userコピー）
killall SwiftyGyaim
rm -rf ~/Library/Input\ Methods/SwiftyGyaim.app
cp -r .build/Build/Products/Release/SwiftyGyaim.app ~/Library/Input\ Methods/

# 配布用インストーラ（.pkg → /Library/Input Methods、Google日本語入力方式）
./Scripts/build-pkg.sh          # dist/SwiftyGyaim-<version>.pkg を生成
# インストール/アップデートはpkgをダブルクリックするだけ（postinstallが旧プロセス
# 終了と旧per-userコピーの掃除を行う）。初回のみシステム設定で入力ソース追加が必要。
# 署名はad-hoc。他のMacへ配る場合は 右クリック→開く（Developer ID署名は
# APP_IDENTITY / INSTALLER_IDENTITY 環境変数で対応可能）
```

Working directory for build commands: `GyaimSwift/`

## Architecture

### Core Input Flow

`GyaimController.swift` is the central IME controller implementing the InputMethodKit protocol. It handles keyboard events via `handle(_:client:)`, manages input state (`inputPat`, `candidates`, `nthCand`, `searchMode`), and coordinates dictionary lookups and candidate display.

### Three-Tier Dictionary System (WordSearch.swift + ConnectionDict.swift)

1. **Connection Dictionary** (`GyaimSwift/Resources/dict.txt`) — Fixed morphological dictionary with conjugation support. Tab-separated format: `romaji[TAB]surface[TAB]input_connection[TAB]output_connection`.
2. **Local Dictionary** (`~/.gyaim/localdict.txt`) — User-registered words, highest priority. Hot reload via mtime check.
3. **Study Dictionary** (`~/.gyaim/studydict.txt`) — Score-based learning (max 10,000 entries; 「淘汰なし」mode is uncapped, ADR-025). 4-column TSV: `reading[TAB]word[TAB]timestamp[TAB]frequency`. Eviction mode selectable in Preferences (MRU / None / Score-based). Default: score-based (Mozc-style). See ADR-014.

Search modes: 0 = prefix matching (incremental), 1 = exact matching + auto-add kana variants, 2 = Google Transliterate async results.

### Google Transliterate (GoogleTransliterate.swift)

内蔵辞書で変換できない語のフォールバック。`https://google.com/transliterate` APIにひらがなを送信し、漢字候補を取得。

- **トリガー方式**: サフィックス文字（デフォルト`` ` ``、設定変更可能）またはキーボードショートカット（設定画面で追加）
- **非同期処理**: URLSession（タイムアウト3秒）→ メインスレッドで候補更新。stale guardで入力変更時の古い結果を破棄
- **複数セグメント結合**: APIの分割応答を直積で結合（例:「ますいとしゆき」→「増井俊之」「増井敏之」等、上限20件）
- **設定キー**: `googleTransliterateTrigger`（String、サフィックス文字。`~/.gyaim/settings.json`）

### Text Conversion (RomaKana.swift)

Bidirectional romaji-kana conversion with 350+ rules in `rklist`. Includes full-width symbol mappings (`?`->`？`, `!`->`！`, etc.).

### UI Components

| File | Purpose |
|------|---------|
| CandidateWindow.swift | 候補ウィンドウ。リスト表示（縦、番号1-9、1ページ9候補）とクラシック表示（横並び、candwin.png背景、1ページ11候補）の2モード対応。候補数は無制限でスペースキー順送りによるページ送り。続きがある場合は末尾に▼インジケータを表示。`CandidateDisplayMode` enumで切り替え |
| PreferencesWindow.swift | キーボードショートカット設定、候補表示スタイル切り替え（NSSegmentedControl）、候補トグル（クリップボード/選択テキスト）、Google変換設定（トリガー文字・ショートカット）、ログ管理UI。動的ウィンドウリサイズ対応 |
| DictEditorWindow.swift | User dictionary editor (NSTableView), add/delete/save/reload |
| KeyBindings.swift | Configurable shortcuts (hiragana/katakana/Google Transliterate), settings.json persistence (`GyaimKeyBindings`), single-key kana confirm |

### Key Constraints

- **IME runs as LSBackgroundOnly** — `NSApp.unhide(nil)` causes focus loss, use `orderFront(nil)` only
- **Ctrl+key in terminals** — Terminal apps intercept Ctrl+key independently of IME; use single-key shortcuts as alternative
- **NSApp.setActivationPolicy** — Use `.accessory` temporarily when opening settings/dict editor windows, revert to `.prohibited` on close
- **Icon must be 20x20 PDF** for Retina-compatible menu bar display
- **User data directory**: `~/.gyaim/` (localdict.txt, studydict.txt)
- **IME切替時の未確定テキスト**: `deactivateServer` で未確定テキストを自動確定する（Mozc/Google日本語入力等と同じ標準動作）。`fix(client: sender)` でクライアントに挿入し、`self.client()` フォールバックで堅牢性を確保

## Testing

### テスト実行

```bash
# ユニットテスト（288テスト）+ SwiftLint（baseline 差分のみ fail）+ Python ツールのテスト
./Scripts/run-unit-tests.sh

# E2Eテスト（アクセシビリティ権限必要、Gyaimインストール済みの状態で実行）
xcodebuild -project Gyaim.xcodeproj -scheme GyaimE2ETests -derivedDataPath .build test
```

### テスト構成

| スイート | ファイル | テスト数 | 内容 |
|---------|---------|---------|------|
| HandleEventTests | Tests/GyaimTests/ | 46 | `routeEvent` 静的メソッドによるキー入力分岐の全網羅 |
| InputModeTests | Tests/GyaimTests/ | 1 | TISモードID→InputModeマッピング（非表示英数モード、ADR-023） |
| ModelSelectionTests | Tests/GyaimTests/ | 3 | customModelPathによるGGUF選択・ラベル導出・フォールバック |
| SecureInputDiagnosticsTests | Tests/GyaimTests/ | 2 | Secure Input残留診断（メッセージ組立・再ログ判定） |
| GoogleTransliterateTests | Tests/GyaimTests/ | 12 | フィルタ・候補ビルド・セグメント結合・トリガー設定 |
| ExternalCandidateTests | Tests/GyaimTests/ | 23 | `isValidExternalCandidate` + `buildPrefixCandidates` |
| PreferencesWindowTests | Tests/GyaimTests/ | 22 | 設定画面UIテスト（初期状態・クリック操作・表示モード切替・淘汰方式・Cmd+W/Cmd+V） |
| CandidateWindowTests | Tests/GyaimTests/ | 13 | 表示モード（リスト/クラシック）の切替・描画・最大候補数・ページ指標・位置計算 |
| CopyTextTests | Tests/GyaimTests/ | 1 | CopyText ファイルI/Oとタイムスタンプ更新条件 |
| RomaKanaTests | Tests/GyaimTests/ | 8 | ローマ字⇔かな変換の双方向テスト |
| WordSearchTests | Tests/GyaimTests/ | 49 | 辞書検索（前方一致・完全一致・登録・トリガーサフィックス・study・eviction・削除・ソースタグ） |
| ContextDictTests | Tests/GyaimTests/ | 9 | 文脈条件付き学習（contextKey・affinity・永続化・削除・減衰・上限） |
| StudyEntryTests | Tests/GyaimTests/ | 6 | StudyEntryスコア計算・EvictionMode既定値・ファイルI/O |
| ConnectionDictTests | Tests/GyaimTests/ | 9 | 連接辞書の検索・同梱辞書の語彙回帰・制約付き合成 |
| ConnectionDictSharingTests | Tests/GyaimTests/ | 3 | 連接辞書のプロセス内共有（同一パス再利用・パス切替・reset） |
| GyaimSettingsTests | Tests/GyaimTests/ | 11 | settings.json 永続化・mtimeキャッシュ・UserDefaults一方向移行・書き込み先の単一性・knownKeysとソースの一致 |
| AIRerankerTests / ZenzRuntimeTests / AIRerankBackendTests | Tests/GyaimTests/ | 41 | ヒューリスティックrerankの順序・同音異義語レビューの選別・backend選択 |
| HomophoneFrequencyGuardTests | Tests/GyaimTests/ | 4 | 同音異義語上書きの頻度ガード（BUG-036、実ログ数値で固定） |
| FastContextReviewSchedulingTests | Tests/GyaimTests/ | 4 | モデルレビュー遅延の判定・遅延設定のクランプ・同期パスがモデルを呼ばないこと（ADR-026） |
| StudySuspectsTests | Tests/GyaimTests/ | 3 | 疑わしい学習エントリ検出（typo完成形・長期未使用・false positive 抑止） |
| FileLoggerRotationTests | Tests/GyaimTests/ | 1 | ログ7世代ローテーションのシフト |
| プロパティテスト（3スイート） | Tests/GyaimTests/ | 5 | PropertyTesting.swiftハーネスによる不変条件検査（validatedOrderの順列性・学習マージの頻度保存と冪等性・combineScoresのzero-sum性）。seed再現可能 |
| GyaimE2ETests | Tests/E2ETests/ | 3 | CGEventによるIME統合テスト（TextEdit上で実操作） |

### テストインフラ

- **MockIMKTextInput** (`Tests/GyaimTests/MockIMKTextInput.swift`) — IMKTextInputプロトコル準拠のモック。`insertedTexts`/`markedTexts` 配列で挿入・マーク済みテキストを記録
- **NSEventFactory** (`Tests/GyaimTests/NSEventFactory.swift`) — テスト用NSEvent生成ヘルパー（`keyDown`, `backspace`, `enter`, `space`, `escape`）
- **E2EHelper** (`Tests/E2ETests/E2EHelper.swift`) — CGEventベースのキー入力シミュレーション。TextEditの起動/終了、Gyaim入力ソースの選択、テキスト取得

### テスト方針

- **キー入力ロジック**: `handle(_:client:)` の分岐ロジックを `routeEvent` 静的メソッドに抽出し、副作用なしでユニットテスト可能にしている
- **UI テスト**: PreferencesWindow を直接インスタンス化し、subview走査でチェックボックスを検索してクリック操作をシミュレート
- **E2E テスト**: CGEvent でキーボードイベントを生成し、インストール済みGyaimをTextEdit上で操作。アクセシビリティ権限が必要

## ADR (Architecture Decision Records)

設計上の重要な判断は `docs/adr/` に ADR として記録する。

- テンプレート: `docs/adr/000-template.md`
- 新規追加時は連番で `NNN-タイトル.md` を作成
- 既存 ADR の変更時は新規 ADR を作成し、旧版の Status を `Superseded by ADR-NNN` に更新

```
docs/adr/
├── 000-template.md
├── 001-migrate-rubymotion-to-swift.md
├── 002-remove-implicit-candidate-injection.md
├── 003-vertical-candidate-window.md
├── 004-configurable-keybindings.md
├── 005-remove-nsapp-unhide.md
├── 006-candidate-window-nspanel.md
├── 007-unified-logging.md
├── 008-clipboard-selected-text-candidates.md
├── 009-route-event-extraction-and-test-strategy.md
├── 010-candidate-display-mode-toggle.md
├── 011-google-transliterate-integration.md
├── 012-commit-preedit-on-deactivation.md
├── 013-three-tier-context-infrastructure.md
├── 014-score-based-study-dict-eviction.md
├── 015-delete-candidate-from-dictionary.md
├── 016-exact-reading-match-priority.md (Superseded by ADR-017)
├── 017-cross-dict-exact-priority.md
├── 018-candidate-window-position-fallback.md
├── 019-gictionary-connection-dict-import.md
├── 020-context-conditioned-study.md
├── 021-exact-homophone-direct-logprob.md
├── 022-dictionary-constrained-generation.md (Superseded by ADR-024)
├── 023-hidden-ascii-roman-input-mode.md
├── 024-remove-tab-ai-pipeline.md
├── 025-eviction-mode-none-is-unlimited.md
├── 026-deferred-model-review.md
└── 027-settings-file-as-single-write-target.md
```

## Logging & Monitoring

`GyaimLogger.swift` に os.Logger ベースのロギング基盤を実装。デフォルト無効（設定キー `loggingEnabled`）。例外として `notice` レベル（Secure Event Input残留診断など、稀で診断価値の高いイベント専用）は `loggingEnabled` に関係なく常時 `gyaim.log` へ記録される。

### カテゴリ

| カテゴリ | 対象 |
|---------|------|
| `input` | キー入力、状態遷移、候補確定 |
| `dict` | 辞書読込、ホットリロード、学習 |
| `conversion` | ローマ字変換（debugのみ） |
| `ui` | ウィンドウ表示/非表示 |
| `config` | ファイルI/O、設定永続化、起動/終了 |

### ログ確認方法

```bash
# Console.app / ターミナル
log stream --predicate 'subsystem == "com.pitecan.inputmethod.SwiftyGyaim"' --level debug

# ファイルログ（info以上。5MBごとにローテーションし gyaim.log.1〜.7 の7世代を保持）
tail -f ~/.gyaim/gyaim.log
```

### 設定画面

Gyaim設定 > ログセクションで有効/無効切替、ログ削除、Finderで表示が可能。

### 候補設定

Gyaim設定 > 候補セクションで以下を切り替え可能（`~/.gyaim/settings.json`、即時反映）:
- **表示スタイル**: NSSegmentedControlでリスト表示（デフォルト）/ クラシック表示を切り替え。設定キー `candidateDisplayMode`（Int, 0=list, 1=classic）
- **クリップボード候補**: コピーから5秒以内の入力時にクリップボード内容を候補に表示（デフォルトON）
- **選択テキスト候補**: アクティブアプリの選択テキストを候補に表示（デフォルトON、IMKTextInput経由で取得可能な範囲のみ）

### Google変換設定

Gyaim設定 > Google変換セクションで以下を設定可能:
- **トリガー文字**: 入力末尾に付けてGoogle変換を発動（デフォルト`` ` ``）。設定キー `googleTransliterateTrigger`
- **ショートカット**: 変換中に押すとGoogle変換を発動（設定画面で追加/削除）。KeyBindingsで永続化

## Context Infrastructure (3-Tier Docs)

arXiv:2602.20478 に基づく3階層ドキュメントシステム（ADR-013）。

### Tier 1: 常時読込 → このファイル (CLAUDE.md)

### Tier 2: 領域特化仕様書 → `docs/specs/`

**ルール（必須 — 違反は禁止）**:
1. `.swift` ファイルを編集する**前に**、下表のTrigger列に該当するspecを**必ずReadすること**（hooksでリマインドされるが、hookが動作しなくてもこのルールは有効）
2. バグ修正後は `docs/specs/bug-memory.md` にエントリを**必ず追記**すること
3. 動作仕様を変更した場合は、対応するspecを**同じコミットで更新**すること（`> Last updated:` の日付も更新）
4. コミット前に `docs/specs/` 内の関連specが最新であることを確認すること

| Spec | Trigger（編集対象） | 内容 |
|------|-------------------|------|
| [input-flow.md](docs/specs/input-flow.md) | GyaimController.swift | キー入力→変換→確定フロー、routeEvent設計 |
| [dictionary-system.md](docs/specs/dictionary-system.md) | WordSearch.swift, ConnectionDict.swift | 3階層辞書、学習、ホットリロード |
| [candidate-window.md](docs/specs/candidate-window.md) | CandidateWindow.swift, PreferencesWindow.swift | 候補表示モード、NSPanel制約 |
| [google-transliterate.md](docs/specs/google-transliterate.md) | GoogleTransliterate.swift | Google API連携、非同期処理、stale guard |
| [imk-constraints.md](docs/specs/imk-constraints.md) | GyaimController.swift, AppDelegate.swift, main.swift | InputMethodKit固有の制約と回避策 |
| [settings.md](docs/specs/settings.md) | GyaimSettings.swift（設定キーを追加・変更する全ファイル） | 設定ストア、全キー一覧と既定値、移行方針（ADR-027） |
| [bug-memory.md](docs/specs/bug-memory.md) | 全ファイル（デバッグ時） | 過去のバグパターンと修正方法 |

### Tier 3: オンデマンド検索 → `docs/adr/`

- `docs/adr/` — 設計判断の経緯（000-027）

### 自動チェック（hooks — `.claude/settings.json`）

セッション開始時に読み込まれる。セッション中にsettings.jsonを変更しても反映されない点に注意。

| イベント | スクリプト | 動作 |
|---------|-----------|------|
| Edit任意ファイル | `spec-read-reminder.sh` | .swiftファイルの場合、対応specのパスを表示 |
| git commit | `spec-freshness-check.sh` | 変更.swiftに対応するspecが今日更新されていなければ⚠️警告 |
| gh pr create | `pr-spec-reminder.sh` | spec更新漏れ確認、bugfixブランチならbug-memory追記リマインド |

**hookが動作しない場合でも、上記Tier 2のルールは手動で遵守すること。**

### メンテナンス

週次（目安30分）: git logから変更を確認し、影響するspecを更新。新規バグはbug-memory.mdに追記。あわせて `python3 GyaimSwift/Tools/ai-rerank/aggregate-fast-context-log.py --last-minutes 10080` で直近1週間の acceptedRanks（acceptedTop1Rate）と byOutcome（fix率・latency）を確認し、悪化があれば eval fixture 化する（issue #57）。
