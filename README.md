# SwiftyGyaim — macOS用 日本語IME

[masui/GyaimMotion](https://github.com/masui/GyaimMotion) のフォークです。
オリジナルは増井俊之氏が RubyMotion で開発した日本語入力システムで、本フォークでは Swift へ全面移行しています。

## 動作環境

- macOS 13.0 (Ventura) 以降
- Apple Silicon (arm64)。配布している pkg は arm64 専用です

## インストール

### 1. ダウンロード

[最新リリース](https://github.com/tanabe1478/SwiftyGyaim/releases/latest) から `SwiftyGyaim-<version>.pkg` をダウンロードします。

### 2. インストーラを実行

ダウンロードした pkg を開き、インストーラの指示に従います。管理者パスワードが求められます。

配布ビルドは Ad-hoc 署名（Apple の公証なし）のため、ダブルクリックでは「開発元を検証できない」と表示されて開けないことがあります。その場合は pkg を Control キーを押しながらクリックして「開く」を選ぶか、システム設定 > プライバシーとセキュリティ の下部に出る「このまま開く」を押してください。

インストール先は `/Library/Input Methods/SwiftyGyaim.app` です。

### 3. 入力ソースの追加（初回のみ）

1. システム設定 > キーボード > 入力ソース の「編集...」を開く
2. 左下の「+」をクリック
3. 「日本語」の中から Gyaim を選んで追加
4. メニューバーの入力メニューから Gyaim に切り替える

### アップデート

新しい pkg を開いてインストールするだけです。インストーラが旧プロセスを終了し、次に IME を使うときに新しいバイナリで起動します。入力ソースの再追加は不要です。

### アンインストール

1. システム設定 > キーボード > 入力ソース から Gyaim を削除
2. `/Library/Input Methods/SwiftyGyaim.app` を削除（管理者権限が必要）
3. 学習辞書などのユーザーデータも消す場合は `~/.gyaim/` を削除

## 使い方

- ローマ字を入力すると候補が表示されます。Space で次の候補、Enter で確定。Backspace（または Esc）は 1 文字削除で、候補を送っている途中なら前の候補に戻ります
- 候補リスト表示中は数字キー 1〜9 で直接選択
- `;` でひらがな確定、`q` でカタカナ確定（キーは設定画面で変更可能）
- 変換中に Tab、または入力末尾に `` ` `` を付けると Google 変換（Google Input Tools API）で辞書にない語を変換
- 候補表示中に Shift+X で、学習辞書・ユーザー辞書のその候補を削除
- 設定・ユーザー辞書エディタは入力メニュー（メニューバーの Gyaim アイコン）から開けます

## 主な機能

- 3層辞書（接続辞書 / ユーザー辞書 / 学習辞書）と、確定時の左文脈を使った同音異義語の選択（文脈学習）
- 同梱の小型言語モデル gyaim-lm-small-public-v1（GGUF、llama.cpp で実行）による候補の並べ替え。設定 `customModelPath` で別の GGUF に差し替え可能
- Google 変換（Tab またはトリガー文字）
- 接続辞書の差し替え: 設定画面から [masui/Gictionary](https://github.com/masui/Gictionary) の URL を指定してインポート
- 候補ウィンドウはリスト表示とクラシック表示（オリジナル Gyaim 風）を切り替え可能
- キーボードショートカット、学習辞書の淘汰方式、クリップボード/選択テキスト候補などを設定画面で変更
- Secure Event Input（パスワード入力欄など）で IME が使えない間は、英数入力に自動で縮退

## 辞書

1. 接続辞書 (`GyaimSwift/Resources/dict.txt`、または `~/.gyaim/connectiondict.txt` にインポートしたもの) — 形態素接続ルール付きの固定辞書
2. ユーザー辞書 (`~/.gyaim/localdict.txt`) — ユーザー登録語（最優先）
3. 学習辞書 (`~/.gyaim/studydict.txt`) — 使用頻度に基づく学習。上限 10,000 件（淘汰方式を「淘汰なし」にすると上限なし）
4. 文脈学習 (`~/.gyaim/contextdict.txt`) — 確定時の左文脈を学習し、同音異義語を文脈で選ぶ（設定で OFF / クリア可能）

## 設定ファイル

設定画面で変更した値は `~/.gyaim/settings.json` に保存されます。旧バージョンからの移行のため、同じキーの UserDefaults 値も fallback として読み込みます。

ログは設定画面で有効にすると `~/.gyaim/gyaim.log` に出力されます（デフォルト無効）。

## 開発者向け：ビルド & インストール

### 前提条件

- Xcode（Command Line Tools だけでは `xcodebuild` が動きません）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` から Xcode プロジェクトを生成します

### ビルドとインストール

```bash
cd GyaimSwift

# Xcode プロジェクト生成（必須。.xcodeproj はリポジトリに含まれていません）
xcodegen generate

# pkg を作ってインストール（推奨）
./Scripts/build-pkg.sh        # dist/SwiftyGyaim-<version>.pkg を生成
open dist/SwiftyGyaim-*.pkg   # インストーラが旧プロセス終了と旧 per-user コピーの掃除も行う
```

pkg を経由せず手元で試すだけなら、Release ビルドを `~/Library/Input Methods/` にコピーしても動きます。Debug ビルドは辞書検索が 3〜4 倍遅く体感が退行するので、インストール用途には使わないでください。

```bash
xcodebuild -project Gyaim.xcodeproj -scheme Gyaim -configuration Release -derivedDataPath .build build
killall SwiftyGyaim
rm -rf ~/Library/Input\ Methods/SwiftyGyaim.app
cp -r .build/Build/Products/Release/SwiftyGyaim.app ~/Library/Input\ Methods/
```

Xcode のスキーム名は `Gyaim`、アプリ名は `SwiftyGyaim` です。

署名は既定で Ad-hoc です。Apple Developer Program に加入している場合は `APP_IDENTITY` / `INSTALLER_IDENTITY` 環境変数で Developer ID 署名できます（`Scripts/build-pkg.sh` 冒頭のコメントを参照）。

### テスト

```bash
cd GyaimSwift
./Scripts/run-unit-tests.sh   # ユニットテスト + Python ツールのテスト（CI と同じ入口）
```

E2E テスト（TextEdit を実際に操作）はアクセシビリティ権限と Gyaim のインストールが必要です。

```bash
xcodebuild -project Gyaim.xcodeproj -scheme GyaimE2ETests -derivedDataPath .build test
```

### ドキュメント

- `CLAUDE.md` / `AGENTS.md` — アーキテクチャと開発ルールの要約
- `docs/specs/` — 領域ごとの仕様（入力フロー、辞書、候補ウィンドウ、Google 変換、IMK の制約、バグメモリ）
- `docs/adr/` — 設計判断の記録
- `GyaimSwift/Tools/model-training/README.md` — 同梱モデルの学習パイプライン

## 関連リンク

- [SwiftyGyaim Scrapbox](https://scrapbox.io/swifty-gyaim/) — 開発メモ・ナレッジベース・フォーラム

## ライセンス

[MIT License](LICENSE) - Copyright (c) 2015-2026 Toshiyuki Masui

オリジナルの [masui/GyaimMotion](https://github.com/masui/GyaimMotion) に由来するライセンスです。

同梱 AI モデルは別ライセンスです。`GyaimSwift/Resources/Models/THIRD_PARTY_NOTICES.txt` と `GyaimSwift/Resources/Models/CC-BY-SA-4.0.txt` を参照してください。

## クレジット

- オリジナル作者: [増井俊之](http://masui.github.io/GyaimMotion/) (2011-2015, RubyMotion)
- Swift移行: tanabe1478
