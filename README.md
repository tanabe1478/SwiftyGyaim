# SwiftyGyaim — macOS用 日本語IME

[masui/GyaimMotion](https://github.com/masui/GyaimMotion) のフォークです。
増井俊之氏が RubyMotion で開発したオリジナルの日本語入力システムをベースに、本プロジェクトでは Swift へ全面的に移行しています。

## 動作環境

- macOS 13.0 (Ventura) 以降
- Apple Silicon (arm64) ※配布している pkg は arm64 専用です

## インストール

### 1. ダウンロード

[最新リリース](https://github.com/tanabe1478/SwiftyGyaim/releases/latest) から `SwiftyGyaim-<version>.pkg` をダウンロードします。

### 2. インストーラの実行

ダウンロードした pkg ファイルを開き、画面の指示に従ってインストールを進めます（途中で管理者パスワードの入力が求められます）。

配布ビルドは Ad-hoc 署名（Apple による公証なし）のため、ダブルクリック時に「開発元を検証できないため開けません」と表示されることがあります。その場合は、pkg ファイルを **Control キーを押しながらクリックして「開く」** を選ぶか、**「システム設定」>「プライバシーとセキュリティ」** の下部に表示される「このまま開く」をクリックしてください。

インストール先は `/Library/Input Methods/SwiftyGyaim.app` です。

### 3. 入力ソースの追加（初回のみ）

1. **「システム設定」>「キーボード」>「入力ソース」** の「編集…」を開く
2. 左下の **「+」** をクリック
3. **「日本語」** の中から **Gyaim** を選択して追加
4. メニューバーの入力メニューから **Gyaim** に切り替える

### アップデート

新しいバージョンの pkg を開いて上書きインストールしてください。インストーラが自動で旧プロセスを終了し、次回 IME 利用時に新しいバイナリで起動します。入力ソースの再追加は不要です。

### アンインストール

1. **「システム設定」>「キーボード」>「入力ソース」** から Gyaim を削除
2. `/Library/Input Methods/SwiftyGyaim.app` を削除（管理者権限が必要）
3. （任意）学習辞書などのユーザーデータも完全に消去する場合は `~/.gyaim/` ディレクトリを削除

## 使い方

- **基本的な入力**: ローマ字を入力すると変換候補が表示されます。Space キーで次の候補を選択し、Enter キーで確定します。Backspace（または Esc）キーは 1 文字削除ですが、候補を選択している途中の場合は前の候補に戻ります。
- **数字キーによる選択**: 候補リストの表示中は、数字キー（1〜9）で直接候補を選択できます。
- **かな・カナ確定**: `;` キーでひらがな確定、`q` キーでカタカナ確定ができます（割り当てキーは設定画面で変更可能）。
- **Google 変換**: 変換中に Tab キーを押すか、入力末尾に `` ` ``（バッククォート）を付けると、Google 変換（Google Input Tools API）を利用して辞書にない語も変換できます。
- **候補の削除**: 候補表示中に Shift+X を押すと、選択中の候補を学習辞書やユーザー辞書から削除できます。
- **設定と辞書管理**: メニューバーの入力メニュー（Gyaim アイコン）から、設定画面やユーザー辞書エディタを開けます。

## 主な機能

- **3層辞書と文脈学習**: 接続辞書・ユーザー辞書・学習辞書の3層構成に加え、確定直前の文脈（左文脈）を学習して適切な同音異義語を優先表示
- **AI（小型言語モデル）による候補並べ替え**: 同梱の小型言語モデル `gyaim-lm-small-public-v1`（GGUF 形式、llama.cpp で実行）による候補リランキング。設定項目 `customModelPath` で任意の GGUF モデルに差し替え可能
- **Google 変換の統合**: Google Input Tools API による辞書外単語の補完（Tab キーまたはトリガー文字）
- **接続辞書の差し替え**: 設定画面から [masui/Gictionary](https://github.com/masui/Gictionary) の URL を指定して接続辞書をインポート可能
- **選べる候補ウィンドウ表示**: 縦型の「リスト表示」と、オリジナル Gyaim 風の「クラシック表示」を好みに応じて切り替え可能
- **柔軟なカスタマイズ**: ショートカットキー、学習辞書の淘汰アルゴリズム、クリップボードや選択テキストからの候補生成などを設定画面から変更可能
- **セキュア入力への自動対応**: パスワード入力欄などの Secure Event Input 環境で IME が制限されている間は、自動で英数入力モードに縮退

## 辞書

1. **接続辞書** (`GyaimSwift/Resources/dict.txt`、または `~/.gyaim/connectiondict.txt` にインポートしたもの) — 形態素接続ルールを持つ基本の固定辞書
2. **ユーザー辞書** (`~/.gyaim/localdict.txt`) — ユーザー登録単語（最優先で候補に表示）
3. **学習辞書** (`~/.gyaim/studydict.txt`) — 使用頻度に基づく動的な学習辞書。標準では上限 10,000 件（淘汰方式を「淘汰なし」に設定した場合は上限なし）
4. **文脈学習** (`~/.gyaim/contextdict.txt`) — 確定直前の文脈（左文脈）を学習し、同音異義語を文脈に応じて選択（設定画面で OFF / クリア可能）

## 設定ファイル

設定画面で変更した値は `~/.gyaim/settings.json` に保存されます。旧バージョンからの移行互換のため、同じキーの UserDefaults 値もフォールバックとして読み込みます。

ログ出力はデフォルトで無効ですが、設定画面で有効にすると `~/.gyaim/gyaim.log` に出力されます。

## 開発者向け：ビルド & インストール

### 前提条件

- **Xcode**（Command Line Tools 単体ではなく、`xcodebuild` が利用可能な Xcode 本体のインストールが必要です）
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `project.yml` から Xcode プロジェクト（`.xcodeproj`）を生成します

### ビルドとインストール手順

```bash
cd GyaimSwift

# Xcode プロジェクト生成（必須。.xcodeproj はリポジトリに含まれていません）
xcodegen generate

# pkg を作成してインストール（推奨）
./Scripts/build-pkg.sh        # dist/SwiftyGyaim-<version>.pkg を生成
open dist/SwiftyGyaim-*.pkg   # インストーラが旧プロセスの終了と旧 per-user コピーのクリーンアップも実行
```

pkg を作成せず手元ですぐ試したい場合は、Release ビルドの成果物を `~/Library/Input Methods/` にコピーして動かすこともできます。なお、Debug ビルドは辞書検索が 3〜4 倍遅くなり入力レスポンスが著しく低下するため、日常的なインストール用途には使用しないでください。

```bash
xcodebuild -project Gyaim.xcodeproj -scheme Gyaim -configuration Release -derivedDataPath .build build
killall SwiftyGyaim
rm -rf ~/Library/Input\ Methods/SwiftyGyaim.app
cp -r .build/Build/Products/Release/SwiftyGyaim.app ~/Library/Input\ Methods/
```

※ Xcode のスキーム名は `Gyaim`、生成されるアプリ名は `SwiftyGyaim` です。

コード署名は既定で Ad-hoc 署名となります。Apple Developer Program に加入している場合は、環境変数 `APP_IDENTITY` および `INSTALLER_IDENTITY` を指定することで Developer ID 署名が可能です（詳細は `Scripts/build-pkg.sh` 冒頭のコメントを参照してください）。

### テスト

```bash
cd GyaimSwift
./Scripts/run-unit-tests.sh   # ユニットテスト + Python ツールのテスト（CI と同じ入口）
```

E2E テスト（TextEdit を実際に操作するテスト）を実行するには、アクセシビリティ権限の付与と Gyaim の事前インストールが必要です。

```bash
xcodebuild -project Gyaim.xcodeproj -scheme GyaimE2ETests -derivedDataPath .build test
```

### ドキュメント

- `CLAUDE.md` / `AGENTS.md` — アーキテクチャと開発ルールの要約
- `docs/specs/` — 領域ごとの仕様（入力フロー、辞書システム、候補ウィンドウ、Google 変換、IMK の制約、バグ知見の記録）
- `docs/adr/` — 設計判断（ADR）の記録
- `GyaimSwift/Tools/model-training/README.md` — 同梱モデルの学習パイプライン

## 関連リンク

- [SwiftyGyaim Scrapbox](https://scrapbox.io/swifty-gyaim/) — 開発メモ・ナレッジベース・フォーラム

## ライセンス

[MIT License](LICENSE) - Copyright (c) 2015-2026 Toshiyuki Masui

オリジナルの [masui/GyaimMotion](https://github.com/masui/GyaimMotion) に由来するライセンスです。

同梱の AI モデルは別ライセンスとなります。詳細は `GyaimSwift/Resources/Models/THIRD_PARTY_NOTICES.txt` および `GyaimSwift/Resources/Models/CC-BY-SA-4.0.txt` を参照してください。

## クレジット

- オリジナル作者: [増井俊之](http://masui.github.io/GyaimMotion/) (2011-2015, RubyMotion)
- Swift 移行: tanabe1478
