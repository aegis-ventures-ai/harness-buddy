.PHONY: project build test run probe release clean

DERIVED := .build/xcode
APP := $(DERIVED)/Build/Products/Debug/Harness\ Butler.app

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project HarnessButler.xcodeproj -scheme HarnessButler -configuration Debug \
		-derivedDataPath $(DERIVED) -quiet build

test:
	cd Packages/HarnessButlerKit && swift test

run: build
	-pkill -x "Harness Butler"
	open $(APP)

# Print what each discovered subscription reports, without the UI.
probe:
	cd Packages/HarnessButlerKit && swift run hb-probe

# Developer ID-signed, notarized DMG in .build/release (see scripts/release.sh).
release:
	scripts/release.sh

clean:
	rm -rf $(DERIVED) HarnessButler.xcodeproj
