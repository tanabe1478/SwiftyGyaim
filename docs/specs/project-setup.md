# Spec: Project Setup

> Trigger: project.yml, Package.swift, run-unit-tests.sh, build-pkg.sh, test.yml, release.yml, Makefile
> Last updated: 2026-11-11 (run-unit-tests.sh が grammar-dict.txt の鮮度を確認 — ADR-042)

## Overview

ビルド・テスト・配布に関するプロジェクト構成。作業ディレクトリは `GyaimSwift/`。

## Build

```bash
xcodegen generate
xcodebuild -project Gyaim.xcodeproj -scheme Gyaim -configuration Release -derivedDataPath .build build
```

- Release 必須（Debug は辞書検索が3〜4倍遅い）
- 配布は `./Scripts/build-pkg.sh` で `dist/SwiftyGyaim-<version>.pkg` を生成。postinstall は旧プロセスの終了、旧 per-user コピーの掃除、`lsregister -f` での再登録、ログイン中ユーザーでの `open` による起動を行う（2026-11-03: 入れ替え直後に新プロセスが消え入力ソースの登録まで外れたため、自動起動に頼らない）

## Test

```bash
./Scripts/run-unit-tests.sh   # xctest + swiftlint --strict --baseline + Python ツール検証（grammar-dict.txt が生成結果と一致することの確認を含む、ADR-042）
xcodebuild -project Gyaim.xcodeproj -scheme GyaimE2ETests -derivedDataPath .build test  # E2E（要アクセシビリティ権限）
```

## Update this spec when

- project.yml / XcodeGen 設定や依存（Packages/LlamaCpp 等）が変わった
- ビルド・テスト・リリース手順が変わった
- CI ワークフロー（`.github/workflows/`）が変わった
