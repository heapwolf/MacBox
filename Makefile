# swift build makes the binary; Virtualization.framework only runs it inside a bundle
# signed with App/MacBox.entitlements, which is all this does.
#
#   make                      debug build, ad-hoc signed
#   make run                  build and launch
#   make release              optimized build
#   make SIGN_IDENTITY="Developer ID Application: …" release

CONFIG ?= debug
SIGN_IDENTITY ?= -

SWIFT_BUILD := swift build -c $(CONFIG) --arch arm64 --disable-index-store
APP := build/$(CONFIG)/MacBox.app
CONTENTS := $(APP)/Contents

.PHONY: all app run release clean

all: app

release:
	$(MAKE) CONFIG=release app

app:
	$(SWIFT_BUILD)
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp "$$($(SWIFT_BUILD) --show-bin-path)/MacBox" $(CONTENTS)/MacOS/MacBox
	cp App/Info.plist $(CONTENTS)/Info.plist
	swiftc -O App/icon.swift -o build/icon
	build/icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $(CONTENTS)/Resources/AppIcon.icns
	codesign --force --sign "$(SIGN_IDENTITY)" \
		--options runtime \
		--entitlements App/MacBox.entitlements \
		$(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

clean:
	rm -rf .build build
