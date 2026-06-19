#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${APP_NAME:-SwiftyGyaim}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/.build}"
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
DMG_SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-}"

cd "$PROJECT_DIR"

"$SCRIPT_DIR/build-pkg.sh"

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
PKG_PATH="$DIST_DIR/pkg/$APP_NAME-$VERSION.pkg"
if [[ ! -f "$PKG_PATH" ]]; then
  echo "error: package not found: $PKG_PATH" >&2
  exit 1
fi

DMG_DIR="$DIST_DIR/dmg"
DMG_PATH="$DMG_DIR/$APP_NAME-$VERSION.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swiftygyaim-dmg.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$DMG_DIR"
cp "$PKG_PATH" "$STAGING_DIR/$APP_NAME.pkg"
cat > "$STAGING_DIR/README.txt" <<EOF
SwiftyGyaim installer
======================

1. Double-click $APP_NAME.pkg.
2. Follow the Installer.app prompts.
3. Open System Settings > Keyboard > Input Sources and add Gyaim.

This development package is unsigned unless INSTALLER_SIGN_IDENTITY was set
when the DMG was created. If macOS blocks the package, Control-click the pkg,
choose Open, and confirm from Privacy & Security.
EOF

rm -f "$DMG_PATH"
/usr/bin/hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

if [[ -n "$DMG_SIGN_IDENTITY" ]]; then
  /usr/bin/codesign --force --sign "$DMG_SIGN_IDENTITY" "$DMG_PATH"
fi

/usr/bin/hdiutil imageinfo "$DMG_PATH" >/dev/null

echo "Built DMG: $DMG_PATH"
