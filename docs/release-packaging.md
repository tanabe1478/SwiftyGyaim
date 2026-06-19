# Release packaging

## Recommended format

SwiftyGyaim releases should be distributed as a DMG containing a macOS installer package:

```text
SwiftyGyaim-<version>.dmg
└── SwiftyGyaim.pkg
```

The package installs the input method system-wide:

```text
/Library/Input Methods/SwiftyGyaim.app
```

This mirrors the Google 日本語入力 macOS distribution shape. As of the 2026-06-19 check, Google's macOS download page points to `https://dl.google.com/japanese-ime/latest/GoogleJapaneseInput.dmg`; that DMG contains `GoogleJapaneseInput.pkg`, and the package installs `GoogleJapaneseInput.app` under `/Library/Input Methods`.

## Building

```bash
cd GyaimSwift
Scripts/build-dmg.sh
```

Outputs:

```text
dist/pkg/SwiftyGyaim-<version>.pkg
dist/dmg/SwiftyGyaim-<version>.dmg
```

For a package only:

```bash
cd GyaimSwift
Scripts/build-pkg.sh
```

## Signing modes

By default, the scripts use ad-hoc app signing and create an unsigned installer package. This is useful for local testing and dogfood distribution, but it is not a smooth general-public macOS distribution experience: Gatekeeper may block the package or app until the user explicitly allows it.

For a public release with fewer warnings, use Developer ID signing and notarization:

```bash
APP_SIGN_IDENTITY="Developer ID Application: ..." \
INSTALLER_SIGN_IDENTITY="Developer ID Installer: ..." \
Scripts/build-dmg.sh
```

Notarization/stapling is not automated yet.

## Installer scripts

The package includes minimal installer scripts:

- `preinstall`: stops a running `SwiftyGyaim` process before replacement
- `postinstall`: verifies and registers `/Library/Input Methods/SwiftyGyaim.app` with Launch Services
