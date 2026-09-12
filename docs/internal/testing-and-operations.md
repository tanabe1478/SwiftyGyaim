# テスト・ビルド・運用

## 開発ディレクトリ

ビルドやテストの作業ディレクトリは `GyaimSwift/` です。

```bash
cd GyaimSwift
```

## Xcodeプロジェクト生成

このリポジトリは XcodeGen を使います。

```bash
xcodegen generate
```

設定は `GyaimSwift/project.yml` にあります。

## ビルド

```bash
xcodebuild -project Gyaim.xcodeproj \
  -scheme Gyaim \
  -configuration Debug \
  -derivedDataPath .build \
  build
```

成果物:

```text
GyaimSwift/.build/Build/Products/Debug/SwiftyGyaim.app
```

## ユニットテスト

現在の推奨コマンド:

```bash
./Scripts/run-unit-tests.sh
```

このスクリプトは以下を行います。

1. `xcodebuild build-for-testing`
2. `.xctest` の拡張属性をクリア
3. `xcrun xctest` でテスト実行
4. `swiftlint lint --strict --baseline .swiftlint-baseline.json`（既存の警告は baseline で凍結し、新規違反だけを fail にする。古い警告を直したら `--write-baseline` で更新）
5. Python ツールのテストと eval gate

背景として、ローカルmacOS/Xcode環境で `xcodebuild ... test` が `Cannot find executable for CFBundle` を出すことがあります。実際には `Contents/MacOS/GyaimTests` が存在しており、`.xctest` に付いた `com.apple.provenance` などの拡張属性がローダー失敗を引き起こすケースがあります。

`run-unit-tests.sh` はこの問題を避けるためのローカル/CI共通入口です。

## テスト構成

| スイート | 役割 |
|---|---|
| `HandleEventTests` | キー入力分岐 |
| `GoogleTransliterateTests` | Google変換候補生成・API応答処理 |
| `ExternalCandidateTests` | 外部候補validation |
| `PreferencesWindowTests` | 設定UI |
| `CandidateWindowTests` | 候補UI、表示モード、位置計算 |
| `CopyTextTests` | クリップボード候補 |
| `RomaKanaTests` | ローマ字かな変換 |
| `WordSearchTests` | 辞書検索・学習・削除 |
| `StudyEntryTests` | 学習辞書entry・score |
| `ConnectionDictTests` | 連接辞書 |

現在のユニットテストは 287 tests です（2026-09-12 時点、約 5 秒で完走）。CLAUDE.md の表が正で、この数字は目安。

## E2Eテスト

```bash
xcodebuild -project Gyaim.xcodeproj \
  -scheme GyaimE2ETests \
  -derivedDataPath .build \
  test
```

E2Eはアクセシビリティ権限とインストール済みSwiftyGyaimが必要です。`CGEvent` でTextEditを操作します。

## ローカルインストール

```bash
killall SwiftyGyaim 2>/dev/null || true
rm -rf ~/Library/Input\ Methods/SwiftyGyaim.app
cp -r .build/Build/Products/Debug/SwiftyGyaim.app ~/Library/Input\ Methods/
```

反映されない場合:

- 入力ソースを切り替える
- `killall SwiftyGyaim`
- ログアウト/ログイン

## リリース

リリースは tag push で `.github/workflows/release.yml` が動きます。

```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

workflow内容:

1. checkout
2. XcodeGen install
3. `xcodegen generate`
4. `./Scripts/run-unit-tests.sh`
5. `./Scripts/build-pkg.sh`（Release build + `dist/SwiftyGyaim-<version>.pkg`）
6. GitHub Release作成（pkg を添付）

配布物は pkg 単体です。dmg での配布は v1.7 で廃止しました（`build-dmg.sh` は #96 以降の `build-pkg.sh` の出力先と食い違い、v1.6 / v1.7 の workflow が失敗していたため削除）。

## ログ確認

ファイルログ:

```bash
tail -f ~/.gyaim/gyaim.log
```

Unified logging:

```bash
log stream --predicate 'subsystem == "com.pitecan.inputmethod.SwiftyGyaim"' --level debug
```

ログがデバッグの邪魔な場合:

```bash
: > ~/.gyaim/gyaim.log
: > ~/.gyaim/gyaim.log.1
: > ~/.gyaim/debug.log
```

## 変更時の運用ルール

### Swiftファイルを編集する場合

`docs/specs/` の対応specを先に読む必要があります。

| 編集対象 | 読むspec |
|---|---|
| `GyaimController.swift` | `input-flow.md`, `imk-constraints.md` |
| `WordSearch.swift`, `ConnectionDict.swift` | `dictionary-system.md` |
| `CandidateWindow.swift`, `PreferencesWindow.swift` | `candidate-window.md` |
| `GoogleTransliterate.swift` | `google-transliterate.md` |
| バグ修正 | `bug-memory.md` |

### バグ修正時

- `docs/specs/bug-memory.md` に追記
- 仕様が変わるなら該当specも更新
- 必要ならADRを追加

### PR作成時

必ず `--repo tanabe1478/SwiftyGyaim` を指定します。

```bash
gh pr create --repo tanabe1478/SwiftyGyaim --base master --head <branch>
```

省略するとフォーク元 `masui/GyaimMotion` に向かう可能性があります。
