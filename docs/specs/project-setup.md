# Spec: Project Setup

> Trigger: project.yml, Package.swift, run-unit-tests.sh, build-pkg.sh, test.yml, release.yml, Makefile, .gitattributes
> Last updated: 2026-10-11 (GyaimCore を SwiftPM パッケージに切り出し、Linux / Windows CI を追加 — ADR-035)

## Overview

ビルド・テスト・配布に関するプロジェクト構成。作業ディレクトリは `GyaimSwift/`。

## ソースの配置（ADR-035）

| 場所 | 内容 |
|---|---|
| `Sources/Gyaim/` | macOS 固有の層: `GyaimController`（IMK）、候補・設定・辞書エディタのウィンドウ、`AppDelegate` / `main`、`KeyBindings`（NSEvent）、Secure Input 診断、Gyazo 画像、`Emulation` |
| `Packages/GyaimCore/Sources/GyaimCore/` | Foundation だけに依存する変換コア: 辞書検索・学習（`WordSearch`、`ConnectionDict`、`ContextDict`、`StudyEntry`）、`RomaKana`、heuristic / モデル rerank（`AIReranker`、`ZenzRuntime*`、`LlamaZenzContext*`、`InProcessAIReranker`）、`GoogleTransliterate`、`GictionaryConnectionImporter`、`GyaimSettings`、`GyaimLogger`、`Config`、`CopyText` |
| `Tests/GyaimTests/` | アプリ層に依存するテスト（`GyaimController`、ウィンドウ、IMK モック、アプリバンドル内のモデルを使うもの） |
| `Packages/GyaimCore/Tests/GyaimCoreTests/` | コアだけで完結するテストと `Fixtures/dictionary-search-golden.json`。`TestPaths.gyaimSwiftDir` で `Resources/dict.txt` などを探す |

**二重ビルド**: Xcode の `Gyaim` / `GyaimTests` ターゲット（project.yml）は `Packages/GyaimCore` 配下のソースとテストを**自分のモジュール（`Gyaim`）に直接コンパイルする**。`Packages/GyaimCore/Package.swift` は同じファイルを SwiftPM パッケージ `GyaimCore` として独立にビルドするためのもので、`swift test` と Windows / Linux の変換サーバ（WinGyaim）がこれを使う。アプリをモジュールとして `GyaimCore` に依存させる（public API 化）のは、Windows サーバ着手時の別作業。

そのため移動したテストは次の形で import する（Xcode ターゲットでは `GyaimCore` モジュールが無いので `Gyaim` に落ちる）。

```swift
#if canImport(GyaimCore)
@testable import GyaimCore
#else
@testable import Gyaim
#endif
```

コアに置けるのは `import Foundation` だけで済むコードに限る（`os`、`CryptoKit`、AppKit、IMK、Carbon、CoreFoundation の関数は不可）。
- ログ: `GyaimLogger` は `#if canImport(os)` で os.Logger を使い、他では `~/.gyaim/gyaim.log` だけに書く
- ネットワーク: `URLSession` は非 Apple では `FoundationNetworking` にあるので `#if canImport(FoundationNetworking) import FoundationNetworking #endif`
- 計時: `CFAbsoluteTimeGetCurrent()` ではなく `Date().timeIntervalSinceReferenceDate`（同じ基準時刻）
- llama.cpp: `Package.swift` は macOS でだけ `../LlamaCpp`（xcframework）に依存する。他では `canImport(llama)` が偽になりモデル採点の経路はコンパイルされない

`.gitattributes`（リポジトリ直下、`* text=auto eol=lf`）で辞書・fixture を LF で checkout させる。Windows の autocrlf で `dict.txt` が CRLF になると、かつては末尾フィールドに CR が残って合成候補が全滅した（現在はパーサ側も CR を許容する。dictionary-system.md）。

## Build

```bash
xcodegen generate
xcodebuild -project Gyaim.xcodeproj -scheme Gyaim -configuration Release -derivedDataPath .build build

# コアだけを SwiftPM でビルド・テスト（macOS / Linux / Windows 共通）
swift test --package-path Packages/GyaimCore
```

- Release 必須（Debug は辞書検索が3〜4倍遅い）
- 配布は `./Scripts/build-pkg.sh` で `dist/SwiftyGyaim-<version>.pkg` を生成
- Windows では swift.org の Swift 6.4 ツールチェーン（winget `Swift.Toolchain`）+ Visual Studio Build Tools で `swift test` が通る（183 テスト、約 11 秒）

## Test

```bash
./Scripts/run-unit-tests.sh   # xctest + swift test（GyaimCore）+ swiftlint --strict --baseline + Python ツール検証
xcodebuild -project Gyaim.xcodeproj -scheme GyaimE2ETests -derivedDataPath .build test  # E2E（要アクセシビリティ権限）
```

SwiftLint の `included` は `Packages/GyaimCore/{Sources,Tests}` も含む。`.swiftlint-baseline.json` のパスは移動に合わせて書き換えてある（baseline はファイルパス + ルール + 行テキストで照合する）。

## CI（`.github/workflows/test.yml`）

| job | runner | 内容 |
|---|---|---|
| `test` | macos-latest | `run-unit-tests.sh` 全体 |
| `core-linux` | ubuntu-latest | `swift test --package-path GyaimSwift/Packages/GyaimCore`。コアへの AppKit / IMK 混入と Foundation 移植性の検出 |
| `core-windows` | windows-latest（compnerd/gha-setup-swift） | 同上。WinGyaim の変換サーバが使う環境での検証 |

## Update this spec when

- project.yml / XcodeGen 設定や依存（Packages/LlamaCpp、Packages/GyaimCore 等）が変わった
- コアとアプリ層のファイル配置や import 規約が変わった
- ビルド・テスト・リリース手順が変わった
- CI ワークフロー（`.github/workflows/`）が変わった
