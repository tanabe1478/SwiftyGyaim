#!/usr/bin/env bash
set -euo pipefail

# SwiftyGyaim インストーラ (.pkg) ビルダー
#
# Google日本語入力等と同様に /Library/Input Methods へ配置するインストーラを作る。
# アップデートは新しいpkgを開いてインストールするだけ（postinstallが旧プロセスを
# 終了し、次回のIME利用時に新バイナリで自動再起動される）。
#
# 使い方:
#   ./Scripts/build-pkg.sh [出力ディレクトリ]   # 既定: dist/
#
# 署名（任意。Apple Developer Program加入時のみ）:
#   APP_IDENTITY="Developer ID Application: ..." \
#   INSTALLER_IDENTITY="Developer ID Installer: ..." ./Scripts/build-pkg.sh
#   未指定時は ad-hoc 署名のまま（配布先では 右クリック→開く が必要）。

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$PROJECT_DIR/dist}"
DERIVED_DATA_PATH="$PROJECT_DIR/.build"
APP="$DERIVED_DATA_PATH/Build/Products/Release/SwiftyGyaim.app"
IDENTIFIER="com.pitecan.inputmethod.SwiftyGyaim"

echo "==> Release ビルド"
xcodebuild -project "$PROJECT_DIR/Gyaim.xcodeproj" -scheme Gyaim \
  -configuration Release -derivedDataPath "$DERIVED_DATA_PATH" build | tail -1

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
echo "==> version $VERSION ($BUILD)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root/Library/Input Methods" "$STAGE/scripts" "$OUT_DIR"
cp -R "$APP" "$STAGE/root/Library/Input Methods/"
# 拡張属性を除去（quarantine等がpayloadに混入するのを防ぐ）。
# com.apple.provenance はSIP保護で除去不可だが、インストール先では不可視の
# メタデータとして復元されるだけで実害はない
xattr -cr "$STAGE/root" 2>/dev/null || true

if [ -n "${APP_IDENTITY:-}" ]; then
  echo "==> アプリ署名: $APP_IDENTITY"
  codesign --force --deep --options runtime \
    --sign "$APP_IDENTITY" "$STAGE/root/Library/Input Methods/SwiftyGyaim.app"
fi

cat > "$STAGE/scripts/postinstall" << 'POSTINSTALL'
#!/bin/bash
# 旧プロセスを終了（次回のIME利用時にmacOSが新バイナリで自動起動する）
killall SwiftyGyaim 2>/dev/null || true

# 開発時代の per-user コピーが残っていると /Library 側と二重登録になるため掃除
CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
  USER_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  if [ -n "$USER_HOME" ] && [ -d "$USER_HOME/Library/Input Methods/SwiftyGyaim.app" ]; then
    rm -rf "$USER_HOME/Library/Input Methods/SwiftyGyaim.app"
  fi
fi
exit 0
POSTINSTALL
chmod +x "$STAGE/scripts/postinstall"

COMPONENT="$STAGE/SwiftyGyaim-component.pkg"
pkgbuild --root "$STAGE/root" \
  --scripts "$STAGE/scripts" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location / \
  "$COMPONENT" > /dev/null

DIST="$STAGE/distribution.xml"
cat > "$DIST" << XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>SwiftyGyaim $VERSION</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_localSystem="true"/>
    <welcome mime-type="text/plain"><![CDATA[SwiftyGyaim をインストールします。

インストール後の手順:
1. システム設定 > キーボード > 入力ソース > 編集 で「+」から
   「日本語」内の Gyaim を追加（初回のみ）
2. 入力メニューから Gyaim を選択

アップデートの場合は追加の操作は不要です。]]></welcome>
    <pkg-ref id="$IDENTIFIER"/>
    <choices-outline><line choice="default"><line choice="$IDENTIFIER"/></line></choices-outline>
    <choice id="default"/>
    <choice id="$IDENTIFIER" visible="false"><pkg-ref id="$IDENTIFIER"/></choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">SwiftyGyaim-component.pkg</pkg-ref>
</installer-gui-script>
XML

PKG="$OUT_DIR/SwiftyGyaim-$VERSION.pkg"
SIGN_ARGS=()
if [ -n "${INSTALLER_IDENTITY:-}" ]; then
  echo "==> インストーラ署名: $INSTALLER_IDENTITY"
  SIGN_ARGS=(--sign "$INSTALLER_IDENTITY")
fi
productbuild --distribution "$DIST" \
  --package-path "$STAGE" \
  "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}" \
  "$PKG" > /dev/null

echo "==> 完成: $PKG"
ls -lh "$PKG"
