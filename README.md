# Gyaim — macOS用 日本語IME

[masui/GyaimMotion](https://github.com/masui/GyaimMotion) のフォークです。
オリジナルは増井俊之氏が RubyMotion で開発した日本語入力システムで、本フォークでは **Swift へ全面移行** しています。

## インストール

### 1. ダウンロード

[最新リリース](https://github.com/tanabe1478/SwiftyGyaim/releases/latest) から `Gyaim-v○○.dmg` をダウンロードしてください。

### 2. DMGを開く

ダウンロードした `.dmg` ファイルをダブルクリックして開きます。

### 3. Gyaim.app をコピー

Finder で以下のフォルダを開きます：

1. Finder のメニューバーから **移動 > フォルダへ移動...** を選択（または `Cmd + Shift + G`）
2. 以下のパスを入力して「移動」をクリック：
   ```
   ~/Library/Input Methods
   ```
3. DMG 内の `Gyaim.app` をこのフォルダにドラッグ＆ドロップでコピーします

### 4. セキュリティの許可

初回起動時に「"Gyaim.app"は開いていません」という警告が表示されます。これは Apple の署名がないためです。

1. **システム設定** を開く
2. **プライバシーとセキュリティ** を選択
3. 画面下部に「"Gyaim.app"は開発元を確認できないため、使用がブロックされました」と表示されるので、**「このまま開く」** をクリック
4. パスワードまたは Touch ID で認証

### 5. 入力ソースの追加

1. **システム設定 > キーボード > 入力ソース** を開く（「入力ソースを編集...」をクリック）
2. 左下の **「+」** ボタンをクリック
3. 「日本語」カテゴリの中から **Gyaim** を選択して追加
4. メニューバーの入力ソースアイコンから Gyaim に切り替えて使用開始

### アンインストール

1. システム設定 > キーボード > 入力ソースから Gyaim を削除
2. `~/Library/Input Methods/Gyaim.app` を削除

## オリジナルとの主な違い

- RubyMotion コードを全て削除し、**Swift (InputMethodKit)** で再実装
- XcodeGen によるプロジェクト管理
- 候補ウィンドウを NSPanel ベースの縦型リストに刷新（クラシック表示も対応）
- キーボードショートカットの設定UI追加
- ユーザー辞書エディタ追加
- Google Input Tools API による変換候補の補完
- os.Logger ベースのロギング基盤（デフォルト無効）

## 動作環境

- macOS 13.0 (Ventura) 以降

## 開発者向け：ビルド & インストール

### 前提条件

- **Xcode** — [Mac App Store](https://apps.apple.com/app/xcode/id497799835) からインストール
- **XcodeGen** — `project.yml` から Xcode プロジェクトを生成するツール。[Homebrew](https://brew.sh/) でインストールできます：
  ```bash
  brew install xcodegen
  ```
  Homebrew が未導入の場合は、先に以下を実行してください：
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

### ビルド手順

```bash
cd GyaimSwift

# Xcode プロジェクト生成
xcodegen generate

# ビルド
xcodebuild -project Gyaim.xcodeproj -scheme Gyaim -configuration Debug -derivedDataPath .build build

# インストール
killall Gyaim
rm -rf ~/Library/Input\ Methods/Gyaim.app
cp -r .build/Build/Products/Debug/Gyaim.app ~/Library/Input\ Methods/
```

## 辞書

3層構成の辞書システム:

1. **接続辞書** (`GyaimSwift/resources/dict.txt`) — 形態素接続ルール付きの固定辞書
2. **ユーザー辞書** (`~/.gyaim/localdict.txt`) — ユーザー登録語（最優先）
3. **学習辞書** (`~/.gyaim/studydict.txt`) — 使用頻度に基づく学習（最大1000件）

## ライセンス

[MIT License](LICENSE) - Copyright (c) 2015-2026 Toshiyuki Masui

オリジナルの [masui/GyaimMotion](https://github.com/masui/GyaimMotion) に由来するライセンスです。

## クレジット

- オリジナル作者: [増井俊之](http://masui.github.io/GyaimMotion/) (2011-2015, RubyMotion)
- Swift移行: tanabe1478
