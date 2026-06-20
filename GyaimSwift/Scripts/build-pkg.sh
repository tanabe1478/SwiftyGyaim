#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${APP_NAME:-SwiftyGyaim}"
SCHEME="${SCHEME:-Gyaim}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/.build}"
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
INSTALL_LOCATION="${INSTALL_LOCATION:-/Library/Input Methods}"
PACKAGE_IDENTIFIER="${PACKAGE_IDENTIFIER:-com.pitecan.inputmethod.SwiftyGyaim.pkg}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
PKG_SCRIPTS_DIR="${PKG_SCRIPTS_DIR:-$SCRIPT_DIR/Packaging/pkg-scripts}"

cd "$PROJECT_DIR"

xcodegen generate
xcodebuild build \
  -project Gyaim.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA"

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found: $APP_PATH" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
PKG_VERSION="${PKG_VERSION:-$VERSION}"
PKG_DIR="$DIST_DIR/pkg"
PKG_PATH="$PKG_DIR/$APP_NAME-$VERSION.pkg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swiftygyaim-pkg.XXXXXX")"
SCRIPTS_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/swiftygyaim-pkg-scripts.XXXXXX")"
COMPONENT_PLIST="$(mktemp "${TMPDIR:-/tmp}/swiftygyaim-components.XXXXXX")"
cleanup() {
  rm -rf "$STAGING_DIR" "$SCRIPTS_STAGING_DIR"
  rm -f "$COMPONENT_PLIST"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR$INSTALL_LOCATION" "$PKG_DIR"
/usr/bin/ditto --norsrc --noextattr "$APP_PATH" "$STAGING_DIR$INSTALL_LOCATION/$APP_NAME.app"
/usr/bin/ditto --norsrc --noextattr "$PKG_SCRIPTS_DIR" "$SCRIPTS_STAGING_DIR"
/usr/bin/sed -i '' \
  -e "s/__SWIFTGYAIM_EXPECTED_SHORT_VERSION__/$VERSION/g" \
  -e "s/__SWIFTGYAIM_EXPECTED_BUNDLE_VERSION__/$BUILD_VERSION/g" \
  "$SCRIPTS_STAGING_DIR/postinstall"
/usr/bin/xattr -cr "$SCRIPTS_STAGING_DIR" 2>/dev/null || true
/usr/bin/find "$SCRIPTS_STAGING_DIR" \
  \( -name '.DS_Store' -o -name '._*' -o -name '.__*' \) -delete
/usr/bin/xattr -cr "$STAGING_DIR$INSTALL_LOCATION/$APP_NAME.app" 2>/dev/null || true
/usr/bin/find "$STAGING_DIR$INSTALL_LOCATION/$APP_NAME.app" \
  \( -name '.DS_Store' -o -name '._*' -o -name '.__*' \) -delete

# Default to ad-hoc app signing for local/general unsigned builds. Set
# APP_SIGN_IDENTITY="Developer ID Application: ..." for signed releases.
/usr/bin/codesign --force --deep --sign "$APP_SIGN_IDENTITY" "$STAGING_DIR$INSTALL_LOCATION/$APP_NAME.app"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIR$INSTALL_LOCATION/$APP_NAME.app"
/usr/bin/xattr -cr "$STAGING_DIR$INSTALL_LOCATION/$APP_NAME.app" 2>/dev/null || true
/usr/bin/find "$STAGING_DIR$INSTALL_LOCATION/$APP_NAME.app" \
  \( -name '.DS_Store' -o -name '._*' -o -name '.__*' \) -delete
/usr/bin/codesign --verify --deep --strict "$STAGING_DIR$INSTALL_LOCATION/$APP_NAME.app"

/usr/bin/pkgbuild --analyze --root "$STAGING_DIR" "$COMPONENT_PLIST"
/usr/bin/python3 - "$COMPONENT_PLIST" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as file:
    components = plistlib.load(file)
for component in components:
    component["BundleIsRelocatable"] = False
with open(path, "wb") as file:
    plistlib.dump(components, file)
PY

PKGBUILD_ARGS=(
  --root "$STAGING_DIR"
  --component-plist "$COMPONENT_PLIST"
  --identifier "$PACKAGE_IDENTIFIER"
  --version "$PKG_VERSION"
  --install-location "/"
  --ownership recommended
  --scripts "$SCRIPTS_STAGING_DIR"
)
if [[ -n "$INSTALLER_SIGN_IDENTITY" ]]; then
  PKGBUILD_ARGS+=(--sign "$INSTALLER_SIGN_IDENTITY")
fi
PKGBUILD_ARGS+=("$PKG_PATH")

rm -f "$PKG_PATH"
export COPYFILE_DISABLE=1
/usr/bin/pkgbuild "${PKGBUILD_ARGS[@]}"

echo "Built package: $PKG_PATH"
if [[ -n "$INSTALLER_SIGN_IDENTITY" ]]; then
  /usr/sbin/pkgutil --check-signature "$PKG_PATH"
else
  echo "Package is unsigned. Set INSTALLER_SIGN_IDENTITY for Developer ID Installer signing."
fi
