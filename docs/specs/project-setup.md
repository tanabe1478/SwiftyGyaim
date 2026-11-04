# Spec: Project Setup

> Trigger: project.yml, Package.swift, run-unit-tests.sh, build-pkg.sh, test.yml, release.yml, Makefile
> Last updated: 2026-11-04 (issue #125 の文脈学習・蒸留テストを追加)

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

`run-unit-tests.sh` は issue #125 の文脈変種のsplit隔離・固定評価の整合性を
`test_context_training.py` で検証する（標準ライブラリのみ、合成データのみ）。
学習用venvにtorch/transformersがある場合は、既存の`test_train_zenz.py`に加えて
`test_context_preference.py`と`test_context_prior.py`で候補損失・教師cache・勾配とmode復元を検証する。

```bash
./Scripts/run-unit-tests.sh   # xctest + swiftlint --strict --baseline + Python ツール検証
xcodebuild -project Gyaim.xcodeproj -scheme GyaimE2ETests -derivedDataPath .build test  # E2E（要アクセシビリティ権限）
```

## Update this spec when

- project.yml / XcodeGen 設定や依存（Packages/LlamaCpp 等）が変わった
- ビルド・テスト・リリース手順が変わった
- CI ワークフロー（`.github/workflows/`）が変わった
