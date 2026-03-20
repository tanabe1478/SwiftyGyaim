---
name: install-ime
description: Build, install, and verify SwiftyGyaim IME. Use for "install", "deploy locally", "ビルドしてインストール", etc.
allowed-tools: Bash, Read, Glob
---

# Install IME Skill

SwiftyGyaimをビルド → インストール → MD5検証する手順。

## Workflow

### Step 1: Build

```bash
xcodebuild -project /PATH/GyaimSwift/Gyaim.xcodeproj -scheme Gyaim -configuration Debug -derivedDataPath /PATH/GyaimSwift/.build build 2>&1 | tail -3
```

ビルド失敗時はここで止める。

### Step 2: Kill existing process

```bash
killall SwiftyGyaim 2>/dev/null
echo "done"
```

### Step 3: Replace app bundle

```bash
rm -rf ~/Library/Input\ Methods/SwiftyGyaim.app
cp -r /PATH/GyaimSwift/.build/Build/Products/Debug/SwiftyGyaim.app ~/Library/Input\ Methods/
```

### Step 4: Verify with MD5

```bash
md5 ~/Library/Input\ Methods/SwiftyGyaim.app/Contents/MacOS/SwiftyGyaim /PATH/GyaimSwift/.build/Build/Products/Debug/SwiftyGyaim.app/Contents/MacOS/SwiftyGyaim
```

MD5が一致することを確認。

### Step 5: Verify running process

```bash
ps aux | grep -i SwiftyGyaim | grep -v grep
```

新しいプロセスが起動していることを確認（タイムスタンプがビルド時刻以降）。

## Notes

- `/PATH/` はリポジトリルート（`/Users/tanabe.nobuyuki/Documents/repositories/SwiftyGyaim`）に置換
- IMEはmacOSが自動的に再起動するので手動起動不要
- プロセスがキャッシュされる場合はログアウト→ログインが必要
- Xcodeプロジェクトが古い場合は事前に `cd GyaimSwift && xcodegen generate` を実行
