DERIVED_DATA = $(PWD)/.build
CONFIGURATION ?= Debug
APP_NAME = SwiftyGyaim

.PHONY: generate build install kill update test clean pkg dmg

generate:
	xcodegen generate

build: generate
	xcodebuild build \
		-project Gyaim.xcodeproj \
		-scheme Gyaim \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA)

install: build
	rm -rf ~/Library/Input\ Methods/$(APP_NAME).app
	cp -r $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app ~/Library/Input\ Methods/

kill:
	-killall $(APP_NAME)

update: kill install

test: generate
	xcodebuild test \
		-project Gyaim.xcodeproj \
		-scheme GyaimTests \
		-derivedDataPath $(DERIVED_DATA)

clean:
	rm -rf $(DERIVED_DATA) Gyaim.xcodeproj dist

pkg:
	Scripts/build-pkg.sh

dmg:
	Scripts/build-dmg.sh
