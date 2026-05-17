APP_NAME := copybara
EXE_NAME := copybara
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
MACOS_DIR := $(CONTENTS)/MacOS
RES_DIR := $(CONTENTS)/Resources
INFO_PLIST_SRC := Resources/Info.plist
ICON_SRC := icon.png
ICNS := $(BUILD_DIR)/AppIcon.icns
EXE := $(BUILD_DIR)/$(EXE_NAME)
DMG := $(BUILD_DIR)/$(APP_NAME).dmg

SOURCES := $(shell find Sources/copybara -name '*.swift' -not -name 'LogfireToken.swift')
LOGFIRE_GEN := Sources/copybara/LogfireToken.swift

# Build straight with swiftc — SwiftPM under CLT-only has a SwiftVersion typealias
# mismatch with the bundled PackageDescription dylib, so we skip it.
SWIFTC_FLAGS := -O \
	-target arm64-apple-macos14.0 \
	-framework AppKit \
	-framework ApplicationServices \
	-framework Carbon \
	-framework CoreGraphics \
	-framework Security \
	-framework SwiftUI

.PHONY: build run new-run clean install reinstall dmg logfire-token-gen

build: $(APP_BUNDLE)

logfire-token-gen:
	@mkdir -p Sources/copybara
	@TOKEN="$${COPYBARA_LOGFIRE_TOKEN-__UNSET__}"; \
	SOURCE="env var"; \
	if [ "$$TOKEN" = "__UNSET__" ]; then \
		if [ -f .env ]; then \
			TOKEN=$$(grep -E '^[[:space:]]*COPYBARA_LOGFIRE_TOKEN=' .env | head -1 \
				| sed -E 's/^[[:space:]]*COPYBARA_LOGFIRE_TOKEN=//' \
				| sed -e 's/^"//' -e 's/"$$//' -e "s/^'//" -e "s/'$$//"); \
			SOURCE=".env"; \
		else \
			TOKEN=""; \
		fi; \
	fi; \
	if [ -n "$$TOKEN" ]; then \
		printf 'enum LogfireBuild { static let token: String? = "%s" }\n' "$$TOKEN" > $(LOGFIRE_GEN); \
		echo "→ Logfire token embedded for this build (from $$SOURCE)"; \
	else \
		echo 'enum LogfireBuild { static let token: String? = nil }' > $(LOGFIRE_GEN); \
		echo "→ Logfire token absent — Config.shared.logfire will be nil"; \
	fi

$(EXE): $(SOURCES) logfire-token-gen
	@mkdir -p "$(BUILD_DIR)"
	@echo "→ Compiling Swift sources"
	@swiftc $(SWIFTC_FLAGS) $(SOURCES) $(LOGFIRE_GEN) -o "$(EXE)"

$(ICNS): $(ICON_SRC)
	@mkdir -p "$(BUILD_DIR)"
	@echo "→ Generating AppIcon.icns from $(ICON_SRC)"
	@rm -rf "$(BUILD_DIR)/AppIcon.iconset"
	@mkdir -p "$(BUILD_DIR)/AppIcon.iconset"
	@sips -z 16 16     "$(ICON_SRC)" --out "$(BUILD_DIR)/AppIcon.iconset/icon_16x16.png"     >/dev/null
	@sips -z 32 32     "$(ICON_SRC)" --out "$(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png"  >/dev/null
	@sips -z 32 32     "$(ICON_SRC)" --out "$(BUILD_DIR)/AppIcon.iconset/icon_32x32.png"     >/dev/null
	@sips -z 64 64     "$(ICON_SRC)" --out "$(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png"  >/dev/null
	@sips -z 128 128   "$(ICON_SRC)" --out "$(BUILD_DIR)/AppIcon.iconset/icon_128x128.png"   >/dev/null
	@sips -z 256 256   "$(ICON_SRC)" --out "$(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png">/dev/null
	@sips -z 256 256   "$(ICON_SRC)" --out "$(BUILD_DIR)/AppIcon.iconset/icon_256x256.png"   >/dev/null
	@sips -z 512 512   "$(ICON_SRC)" --out "$(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png">/dev/null
	@sips -z 512 512   "$(ICON_SRC)" --out "$(BUILD_DIR)/AppIcon.iconset/icon_512x512.png"   >/dev/null
	@cp "$(ICON_SRC)" "$(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png"
	@iconutil -c icns "$(BUILD_DIR)/AppIcon.iconset" -o "$(ICNS)"
	@rm -rf "$(BUILD_DIR)/AppIcon.iconset"

$(APP_BUNDLE): $(EXE) $(INFO_PLIST_SRC) $(ICNS)
	@echo "→ Assembling $(APP_BUNDLE)"
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	@cp "$(EXE)" "$(MACOS_DIR)/$(EXE_NAME)"
	@cp "$(INFO_PLIST_SRC)" "$(CONTENTS)/Info.plist"
	@cp "$(ICNS)" "$(RES_DIR)/AppIcon.icns"
	@echo "→ Codesigning"
	@if security find-identity -p codesigning | grep -q "copybara-local"; then \
		echo "   using stable identity: copybara-local"; \
		codesign -s "copybara-local" --force --deep "$(APP_BUNDLE)" 2>&1 | sed 's/^/   /'; \
	else \
		echo "   (no copybara-local cert found; falling back to ad-hoc — TCC will re-prompt on every build)"; \
		codesign -s - --force --deep "$(APP_BUNDLE)" 2>&1 | sed 's/^/   /'; \
	fi
	@echo "✓ Built $(APP_BUNDLE)"

run: build
	@pkill -x $(EXE_NAME) 2>/dev/null; true
	@echo "→ Launching"
	@open "$(APP_BUNDLE)"

new-run:
	@pkill -x $(EXE_NAME) 2>/dev/null; true
	@echo "→ Wiping Keychain API key and app preferences (first-run simulation)"
	@security delete-generic-password -s com.yanyiphei.copybara -a openrouter_api_key >/dev/null 2>&1; true
	@defaults delete com.yanyiphei.copybara >/dev/null 2>&1; true
	@$(MAKE) run

install: build
	@echo "→ Installing to /Applications"
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "/Applications/"
	@echo "✓ Installed /Applications/$(APP_NAME).app"

reinstall: install
	@pkill -x $(EXE_NAME) 2>/dev/null; true
	@open "/Applications/$(APP_NAME).app"

dmg:
	@echo "→ DMG build: stripping COPYBARA_LOGFIRE_TOKEN for this build"
	@COPYBARA_LOGFIRE_TOKEN= $(MAKE) $(APP_BUNDLE)
	@echo "→ Staging DMG contents"
	@rm -rf "$(BUILD_DIR)/dmg-staging" "$(DMG)"
	@mkdir -p "$(BUILD_DIR)/dmg-staging"
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/dmg-staging/"
	@cp Resources/DMG-README.txt "$(BUILD_DIR)/dmg-staging/README.txt"
	@ln -s /Applications "$(BUILD_DIR)/dmg-staging/Applications"
	@echo "→ Building $(DMG)"
	@hdiutil create \
		-volname "$(APP_NAME)" \
		-srcfolder "$(BUILD_DIR)/dmg-staging" \
		-ov -format UDZO \
		"$(DMG)" >/dev/null
	@rm -rf "$(BUILD_DIR)/dmg-staging"
	@echo "✓ Built $(DMG)"

clean:
	@rm -rf "$(BUILD_DIR)"
	@echo "✓ Cleaned"
