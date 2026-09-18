# Spec: Project Setup

> Trigger: project.yml, Package.swift, run-unit-tests.sh, build-pkg.sh, test.yml, release.yml, Makefile
> Last updated: 2026-09-15

## Overview

ビルド・テスト・配布に関するプロジェクト構成。作業ディレクトリは `GyaimSwift/`。

## Build

```bash
xcodegen generate
xcodebuild -project Gyaim.xcodeproj -scheme Gyaim -configuration Release -derivedDataPath .build build
```

- Release 必須（Debug は辞書検索が3〜4倍遅い）
- 配布は `./Scripts/build-pkg.sh` で `dist/SwiftyGyaim-<version>.pkg` を生成

## Test

```bash
./Scripts/run-unit-tests.sh   # xctest + swiftlint --strict --baseline + Python ツール検証
xcodebuild -project Gyaim.xcodeproj -scheme GyaimE2ETests -derivedDataPath .build test  # E2E（要アクセシビリティ権限）
```

## Update this spec when

- project.yml / XcodeGen 設定や依存（Packages/LlamaCpp 等）が変わった
- ビルド・テスト・リリース手順が変わった
- CI ワークフロー（`.github/workflows/`）が変わった
