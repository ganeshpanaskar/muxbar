# Muxbar — builds with Command Line Tools only (no Xcode).
VERSION   := 0.1.0
BUILD     := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
BUNDLE_ID := io.github.ganeshpanaskar.muxbar
APP       := build/Muxbar.app
DEST      := $(HOME)/Applications/Muxbar.app

.PHONY: build bundle install test clean e2e

build:
	swift build -c release --product Muxbar

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/Muxbar" $(APP)/Contents/MacOS/Muxbar
	sed -e 's/@VERSION@/$(VERSION)/' -e 's/@BUILD@/$(BUILD)/' Resources/Info.plist > $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns Resources/AppIcon-light.png Resources/AppIcon-dark.png Resources/launch-light.svg Resources/launch-dark.svg $(APP)/Contents/Resources/
	codesign --force --sign - --identifier $(BUNDLE_ID) $(APP)

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
