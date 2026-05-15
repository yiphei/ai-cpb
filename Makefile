APP_NAME := ai-cpb
EXE_NAME := aicpb
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
MACOS_DIR := $(CONTENTS)/MacOS
RES_DIR := $(CONTENTS)/Resources
INFO_PLIST_SRC := Resources/Info.plist
EXE := $(BUILD_DIR)/$(EXE_NAME)
DMG := $(BUILD_DIR)/$(APP_NAME).dmg

SOURCES := $(shell find Sources/aicpb -name '*.swift')

# Build straight with swiftc — SwiftPM under CLT-only has a SwiftVersion typealias
# mismatch with the bundled PackageDescription dylib, so we skip it.
SWIFTC_FLAGS := -O \
	-target arm64-apple-macos14.0 \
	-framework AppKit \
	-framework ApplicationServices \
	-framework Carbon \
	-framework CoreGraphics

.PHONY: build run clean install reinstall dmg

build: $(APP_BUNDLE)

$(EXE): $(SOURCES)
	@mkdir -p "$(BUILD_DIR)"
	@echo "→ Compiling Swift sources"
	@swiftc $(SWIFTC_FLAGS) $(SOURCES) -o "$(EXE)"

$(APP_BUNDLE): $(EXE) $(INFO_PLIST_SRC)
	@echo "→ Assembling $(APP_BUNDLE)"
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	@cp "$(EXE)" "$(MACOS_DIR)/$(EXE_NAME)"
	@cp "$(INFO_PLIST_SRC)" "$(CONTENTS)/Info.plist"
	@echo "→ Codesigning"
	@if security find-identity -p codesigning | grep -q "ai-cpb-local"; then \
		echo "   using stable identity: ai-cpb-local"; \
		codesign -s "ai-cpb-local" --force --deep "$(APP_BUNDLE)" 2>&1 | sed 's/^/   /'; \
	else \
		echo "   (no ai-cpb-local cert found; falling back to ad-hoc — TCC will re-prompt on every build)"; \
		codesign -s - --force --deep "$(APP_BUNDLE)" 2>&1 | sed 's/^/   /'; \
	fi
	@echo "✓ Built $(APP_BUNDLE)"

run: build
	@pkill -x $(EXE_NAME) 2>/dev/null; true
	@echo "→ Launching"
	@open "$(APP_BUNDLE)"

install: build
	@echo "→ Installing to /Applications"
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "/Applications/"
	@echo "✓ Installed /Applications/$(APP_NAME).app"

reinstall: install
	@pkill -x $(EXE_NAME) 2>/dev/null; true
	@open "/Applications/$(APP_NAME).app"

dmg: $(APP_BUNDLE)
	@echo "→ Staging DMG contents"
	@rm -rf "$(BUILD_DIR)/dmg-staging" "$(DMG)"
	@mkdir -p "$(BUILD_DIR)/dmg-staging"
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/dmg-staging/"
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
