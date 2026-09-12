DERIVED_DATA = $(PWD)/.build
# Release が既定。Debug は辞書検索が 3〜4 倍遅く、インストール用途に使うと
# 「変換が遅い」退行になる（2026-08-10）。ユニットテストは test target が Debug で走る。
CONFIGURATION ?= Release
APP_NAME = SwiftyGyaim

.PHONY: generate build install install-user kill update test clean pkg

generate:
	xcodegen generate

build: generate
	xcodebuild build \
		-project Gyaim.xcodeproj \
		-scheme Gyaim \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA)

# 推奨インストール: pkg を作って開く（/Library/Input Methods、旧プロセス終了と
# 旧 per-user コピーの掃除は postinstall が行う。README 参照）
install: pkg
	open $(PWD)/dist/$(APP_NAME)-*.pkg

# 開発用: per-user コピー。pkg で /Library に入れている環境では二重登録になるので
# 使わない。Release 以外を指定した場合は中断する。
install-user: build
	@test "$(CONFIGURATION)" = "Release" || { echo "install-user は Release 限定です（CONFIGURATION=$(CONFIGURATION)）"; exit 1; }
	rm -rf ~/Library/Input\ Methods/$(APP_NAME).app
	cp -r $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app ~/Library/Input\ Methods/

kill:
	-killall $(APP_NAME)

update: install

test: generate
	xcodebuild test \
		-project Gyaim.xcodeproj \
		-scheme GyaimTests \
		-derivedDataPath $(DERIVED_DATA)

clean:
	rm -rf $(DERIVED_DATA) Gyaim.xcodeproj dist

pkg:
	Scripts/build-pkg.sh
