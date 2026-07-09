# SwiftyGyaim — macOS用 日本語IME

[masui/GyaimMotion](https://github.com/masui/GyaimMotion) のフォークです。
オリジナルは増井俊之氏が RubyMotion で開発した日本語入力システムで、本フォークでは **Swift へ全面移行** しています。

## インストール

### 1. ダウンロード

[最新リリース](https://github.com/tanabe1478/SwiftyGyaim/releases/latest) から `SwiftyGyaim-<version>.dmg` をダウンロードしてください。

### 2. DMGを開く

ダウンロードした `.dmg` ファイルをダブルクリックして開きます。

### 3. インストーラを実行

DMG 内の `SwiftyGyaim.pkg` をダブルクリックして、インストーラの指示に従います。

SwiftyGyaim は `/Library/Input Methods/SwiftyGyaim.app` にインストールされます。インストール時に管理者権限が必要です。

### 4. セキュリティの許可

配布ビルドは Ad-hoc 署名 / 未 notarize の場合があるため、初回インストール時に macOS のセキュリティ機能によりブロックされることがあります。

その場合は `SwiftyGyaim.pkg` を Control キーを押しながらクリックして **開く** を選択するか、**システム設定 > プライバシーとセキュリティ** から許可してください。

### 5. 入力ソースの追加

1. **システム設定 > キーボード > 入力ソース** を開く（「入力ソースを編集...」をクリック）
2. 左下の **「+」** ボタンをクリック
3. 「日本語」カテゴリの中から **Gyaim** を選択して追加
4. メニューバーの入力ソースアイコンから Gyaim に切り替えて使用開始

### アンインストール

1. システム設定 > キーボード > 入力ソースから Gyaim を削除
2. `/Library/Input Methods/SwiftyGyaim.app` を削除

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

# インストール（ユーザー領域への手動コピー）
killall SwiftyGyaim
rm -rf ~/Library/Input\ Methods/SwiftyGyaim.app
cp -r .build/Build/Products/Debug/SwiftyGyaim.app ~/Library/Input\ Methods/
```

### 配布用 DMG / PKG の作成

Google 日本語入力と同様に、DMG 内に `.pkg` を含める形式で作成できます。

```bash
cd GyaimSwift
Scripts/build-dmg.sh
```

成果物:

```text
GyaimSwift/dist/pkg/SwiftyGyaim-<version>.pkg
GyaimSwift/dist/dmg/SwiftyGyaim-<version>.dmg
```

詳細は [docs/release-packaging.md](docs/release-packaging.md) を参照してください。

## 辞書

3層構成の辞書システム:

1. **接続辞書** (`GyaimSwift/resources/dict.txt`) — 形態素接続ルール付きの固定辞書
2. **ユーザー辞書** (`~/.gyaim/localdict.txt`) — ユーザー登録語（最優先）
3. **学習辞書** (`~/.gyaim/studydict.txt`) — 使用頻度に基づく学習（最大10,000件、淘汰方式は設定可能）
4. **文脈学習** (`~/.gyaim/contextdict.txt`) — 確定時の左文脈を学習し、同音異義語を文脈で選ぶ（設定でOFF/クリア可能）

## 設定ファイル

設定画面で変更した値は `~/.gyaim/settings.json` に保存されます。既存バージョンからの移行互換のため、同じキーの UserDefaults 値も fallback として読み込みます。

## 関連リンク

- [SwiftyGyaim Scrapbox](https://scrapbox.io/swifty-gyaim/) — 開発メモ・ナレッジベース・フォーラム

## ライセンス

[MIT License](LICENSE) - Copyright (c) 2015-2026 Toshiyuki Masui

オリジナルの [masui/GyaimMotion](https://github.com/masui/GyaimMotion) に由来するライセンスです。

同梱AIモデルは別ライセンスです。`GyaimSwift/Resources/Models/THIRD_PARTY_NOTICES.txt` と `GyaimSwift/Resources/Models/CC-BY-SA-4.0.txt` を参照してください。

## クレジット

- オリジナル作者: [増井俊之](http://masui.github.io/GyaimMotion/) (2011-2015, RubyMotion)
- Swift移行: tanabe1478
