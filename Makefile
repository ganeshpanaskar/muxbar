# Muxbar — builds with Command Line Tools only (no Xcode).
VERSION   := 0.2.0
BUILD     := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
BUNDLE_ID := io.github.ganeshpanaskar.muxbar
APP       := build/Muxbar.app
DEST      := $(HOME)/Applications/Muxbar.app
# Isolated copy for tests (own bundle id, so its Dock tile, notifications and privacy grants are
# separate). Run it with scripts/test-instance.sh; it never touches the installed Muxbar.
TEST_APP       := build/MuxbarTest.app
TEST_BUNDLE_ID := io.github.ganeshpanaskar.muxbar.test

.PHONY: build bundle bundle-test install test clean e2e

build:
	swift build -c release --product Muxbar

# $(call make_bundle,APP,BUNDLE_ID,NAME)
define make_bundle
	rm -rf "$(1)"
	mkdir -p "$(1)/Contents/MacOS" "$(1)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/Muxbar" "$(1)/Contents/MacOS/Muxbar"
	sed -e 's/@VERSION@/$(VERSION)/' -e 's/@BUILD@/$(BUILD)/' -e 's/@BUNDLE_ID@/$(2)/' -e 's/@NAME@/$(3)/' Resources/Info.plist > "$(1)/Contents/Info.plist"
	cp Resources/AppIcon.icns Resources/AppIcon-light.png Resources/AppIcon-dark.png Resources/launch-light.svg Resources/launch-dark.svg "$(1)/Contents/Resources/"
	cp -R agent-plugin "$(1)/Contents/Resources/agent-plugin"
	scripts/sign.sh "$(1)" $(2)
endef

bundle: build
	$(call make_bundle,$(APP),$(BUNDLE_ID),Muxbar)

bundle-test: build
	$(call make_bundle,$(TEST_APP),$(TEST_BUNDLE_ID),Muxbar Test)

install: bundle
	-"$(DEST)/Contents/MacOS/Muxbar" --cli quit >/dev/null 2>&1
	-pkill -f 'Muxbar.app/Contents/MacOS/Muxbar$$' >/dev/null 2>&1; sleep 1
	mkdir -p $(HOME)/Applications
	rm -rf "$(DEST)"
	cp -R $(APP) "$(DEST)"
	open "$(DEST)"

# Incremental test rebuilds with Command Line Tools sometimes lose the swift-testing macro plugin;
# passing its path explicitly makes them reliable.
TESTING_PLUGINS := $(shell dirname "$$(xcrun -f swift 2>/dev/null || echo /Library/Developer/CommandLineTools/usr/bin/swift)")/../lib/swift/host/plugins/testing

test:
	swift test -Xswiftc -plugin-path -Xswiftc "$(TESTING_PLUGINS)"

e2e:
	scripts/e2e.sh

clean:
	rm -rf .build build
