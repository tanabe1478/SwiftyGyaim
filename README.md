# SwiftyGyaim — macOS用 日本語IME

[masui/GyaimMotion](https://github.com/masui/GyaimMotion) のフォークです。
オリジナルは増井俊之氏が RubyMotion で開発した日本語入力システムで、本フォークでは **Swift へ全面移行** しています。

## インストール

### 1. ダウンロード

[最新リリース](https://github.com/tanabe1478/SwiftyGyaim/releases/latest) から `Gyaim-v○○.dmg` をダウンロードしてください。

### 2. DMGを開く

ダウンロードした `.dmg` ファイルをダブルクリックして開きます。

### 3. SwiftyGyaim.app をコピー

Finder で以下のフォルダを開きます：

1. Finder のメニューバーから **移動 > フォルダへ移動...** を選択（または `Cmd + Shift + G`）
2. 以下のパスを入力して「移動」をクリック：
   ```
   ~/Library/Input Methods
   ```
3. DMG 内の `SwiftyGyaim.app` をこのフォルダにドラッグ＆ドロップでコピーします

### 4. セキュリティの許可

SwiftyGyaim は Ad-hoc 署名のため、初回起動時に macOS のセキュリティ機能によりブロックされます。

1. **システム設定** > **プライバシーとセキュリティ** を開く
2. 画面下部に「お使いのMacを保護するために"SwiftyGyaim"がブロックされました」と表示されている場合は **「このまま開く」** をクリックし、手順 5 へ進んでください

> **表示されない場合（macOS 26 以降で発生することがあります）:**
>
> 1. `~/Library/Input Methods` フォルダ内の `SwiftyGyaim.app` をダブルクリック
> 2. 「"SwiftyGyaim"は開いていません」ダイアログが表示されたら **「完了」** をクリック
> 3. **システム設定を一度終了して再度開き**、プライバシーとセキュリティを選択
> 4. 「お使いのMacを保護するために"SwiftyGyaim"がブロックされました」が表示されるので **「このまま開く」** をクリック

3. 「"SwiftyGyaim"を開きますか？」ダイアログで **「このまま開く」** をクリック
4. パスワードまたは Touch ID で認証

### 5. 入力ソースの追加

1. **システム設定 > キーボード > 入力ソース** を開く（「入力ソースを編集...」をクリック）
2. 左下の **「+」** ボタンをクリック
3. 「日本語」カテゴリの中から **Gyaim** を選択して追加
4. メニューバーの入力ソースアイコンから Gyaim に切り替えて使用開始

### アンインストール

1. システム設定 > キーボード > 入力ソースから Gyaim を削除
2. `~/Library/Input Methods/SwiftyGyaim.app` を削除

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
- **XcodeGen** — `project.yml` から Xcode プロジェクトを生成するツール。インストール方法は [XcodeGen のリポジトリ](https://github.com/yonaskolb/XcodeGen) を参照してください

### ビルド手順

```bash
cd GyaimSwift

# Xcode プロジェクト生成（必須 — .xcodeproj はリポジトリに含まれていません）
xcodegen generate

# ビルド
xcodebuild -project Gyaim.xcodeproj -scheme Gyaim -configuration Debug -derivedDataPath .build build

# ビルド成果物は .build/Build/Products/Debug/SwiftyGyaim.app に生成されます
# （Xcodeのスキーム名は "Gyaim" ですが、アプリ名は "SwiftyGyaim" です）

# インストール
killall SwiftyGyaim
rm -rf ~/Library/Input\ Methods/SwiftyGyaim.app
cp -r .build/Build/Products/Debug/SwiftyGyaim.app ~/Library/Input\ Methods/
```

## 辞書

3層構成の辞書システム:

1. **接続辞書** (`GyaimSwift/resources/dict.txt`) — 形態素接続ルール付きの固定辞書
2. **ユーザー辞書** (`~/.gyaim/localdict.txt`) — ユーザー登録語（最優先）
3. **学習辞書** (`~/.gyaim/studydict.txt`) — 使用頻度に基づく学習（最大1000件）

## 関連リンク

- [SwiftyGyaim Scrapbox](https://scrapbox.io/swifty-gyaim/) — 開発メモ・ナレッジベース・フォーラム

## ライセンス

[MIT License](LICENSE) - Copyright (c) 2015-2026 Toshiyuki Masui

オリジナルの [masui/GyaimMotion](https://github.com/masui/GyaimMotion) に由来するライセンスです。

## クレジット

- オリジナル作者: [増井俊之](http://masui.github.io/GyaimMotion/) (2011-2015, RubyMotion)
- Swift移行: tanabe1478
