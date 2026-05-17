APP_NAME := "copybara"
EXE_NAME := "copybara"
BUNDLE_ID := "com.yanyiphei.copybara"
BUILD_DIR := "build"
APP_BUNDLE := BUILD_DIR + "/" + APP_NAME + ".app"
CONTENTS := APP_BUNDLE + "/Contents"
MACOS_DIR := CONTENTS + "/MacOS"
RES_DIR := CONTENTS + "/Resources"
INFO_PLIST_SRC := "Resources/Info.plist"
ICON_SRC := "icon.png"
ICNS := "Resources/AppIcon.icns"
EXE := BUILD_DIR + "/" + EXE_NAME
DMG := BUILD_DIR + "/" + APP_NAME + ".dmg"
LOGFIRE_GEN := "Sources/copybara/LogfireToken.swift"
INSTALLED_APP := "/Applications/" + APP_NAME + ".app"

# Build straight with swiftc — SwiftPM under CLT-only has a SwiftVersion typealias
# mismatch with the bundled PackageDescription dylib, so we skip it.
SWIFTC_FLAGS := "-O -target arm64-apple-macos14.0 -framework AppKit -framework ApplicationServices -framework Carbon -framework CoreGraphics -framework Security -framework SwiftUI"

# Build, replace the installed app, relaunch. Keychain, TCC grants, and prefs are untouched.
update: _bundle
    @pkill -x {{EXE_NAME}} 2>/dev/null; true
    @echo "→ Replacing {{INSTALLED_APP}}"
    @rm -rf "{{INSTALLED_APP}}"
    @cp -R "{{APP_BUNDLE}}" "/Applications/"
    @echo "→ Launching"
    @open "{{INSTALLED_APP}}"

# Wipe Keychain, prefs, and TCC grants, then install and launch — simulates a first-run install.
install: _bundle
    @pkill -x {{EXE_NAME}} 2>/dev/null; true
    @echo "→ Wiping OpenRouter API key from Keychain"
    @security delete-generic-password -s {{BUNDLE_ID}} -a openrouter_api_key >/dev/null 2>&1; true
    @echo "→ Wiping app preferences"
    @defaults delete {{BUNDLE_ID}} >/dev/null 2>&1; true
    @echo "→ Resetting Screen Recording + Accessibility grants for {{BUNDLE_ID}}"
    @tccutil reset ScreenCapture {{BUNDLE_ID}} >/dev/null 2>&1; true
    @tccutil reset Accessibility {{BUNDLE_ID}} >/dev/null 2>&1; true
    @echo "→ Installing {{INSTALLED_APP}}"
    @rm -rf "{{INSTALLED_APP}}"
    @cp -R "{{APP_BUNDLE}}" "/Applications/"
    @echo "→ Launching"
    @open "{{INSTALLED_APP}}"

# Build a redistributable DMG with no embedded Logfire token.
dmg:
    @echo "→ DMG build: stripping COPYBARA_LOGFIRE_TOKEN for this build"
    @COPYBARA_LOGFIRE_TOKEN= just _bundle
    @echo "→ Staging DMG contents"
    @rm -rf "{{BUILD_DIR}}/dmg-staging" "{{DMG}}"
    @mkdir -p "{{BUILD_DIR}}/dmg-staging"
    @cp -R "{{APP_BUNDLE}}" "{{BUILD_DIR}}/dmg-staging/"
    @cp Resources/DMG-README.txt "{{BUILD_DIR}}/dmg-staging/README.txt"
    @ln -s /Applications "{{BUILD_DIR}}/dmg-staging/Applications"
    @echo "→ Building {{DMG}}"
    @hdiutil create \
        -volname "{{APP_NAME}}" \
        -srcfolder "{{BUILD_DIR}}/dmg-staging" \
        -ov -format UDZO \
        "{{DMG}}" >/dev/null
    @rm -rf "{{BUILD_DIR}}/dmg-staging"
    @echo "✓ Built {{DMG}}"

# --- private build helpers ---

_logfire-token-gen:
    @mkdir -p Sources/copybara
    @TOKEN="${COPYBARA_LOGFIRE_TOKEN-__UNSET__}"; \
    SOURCE="env var"; \
    if [ "$TOKEN" = "__UNSET__" ]; then \
        if [ -f .env ]; then \
            TOKEN=$(grep -E '^[[:space:]]*COPYBARA_LOGFIRE_TOKEN=' .env | head -1 \
                | sed -E 's/^[[:space:]]*COPYBARA_LOGFIRE_TOKEN=//' \
                | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"); \
            SOURCE=".env"; \
        else \
            TOKEN=""; \
        fi; \
    fi; \
    if [ -n "$TOKEN" ]; then \
        printf 'enum LogfireBuild { static let token: String? = "%s" }\n' "$TOKEN" > {{LOGFIRE_GEN}}; \
        echo "→ Logfire token embedded for this build (from $SOURCE)"; \
    else \
        echo 'enum LogfireBuild { static let token: String? = nil }' > {{LOGFIRE_GEN}}; \
        echo "→ Logfire token absent — Config.shared.logfire will be nil"; \
    fi

_compile: _logfire-token-gen
    @mkdir -p "{{BUILD_DIR}}"
    @echo "→ Compiling Swift sources"
    @SOURCES=$(find Sources/copybara -name '*.swift' -not -name 'LogfireToken.swift'); \
    swiftc {{SWIFTC_FLAGS}} $SOURCES {{LOGFIRE_GEN}} -o "{{EXE}}"

_icns:
    @mkdir -p "{{BUILD_DIR}}"
    @echo "→ Generating AppIcon.icns from {{ICON_SRC}}"
    @rm -rf "{{BUILD_DIR}}/AppIcon.iconset"
    @mkdir -p "{{BUILD_DIR}}/AppIcon.iconset"
    @sips -z 16 16     "{{ICON_SRC}}" --out "{{BUILD_DIR}}/AppIcon.iconset/icon_16x16.png"     >/dev/null
    @sips -z 32 32     "{{ICON_SRC}}" --out "{{BUILD_DIR}}/AppIcon.iconset/icon_16x16@2x.png"  >/dev/null
    @sips -z 32 32     "{{ICON_SRC}}" --out "{{BUILD_DIR}}/AppIcon.iconset/icon_32x32.png"     >/dev/null
    @sips -z 64 64     "{{ICON_SRC}}" --out "{{BUILD_DIR}}/AppIcon.iconset/icon_32x32@2x.png"  >/dev/null
    @sips -z 128 128   "{{ICON_SRC}}" --out "{{BUILD_DIR}}/AppIcon.iconset/icon_128x128.png"   >/dev/null
    @sips -z 256 256   "{{ICON_SRC}}" --out "{{BUILD_DIR}}/AppIcon.iconset/icon_128x128@2x.png">/dev/null
    @sips -z 256 256   "{{ICON_SRC}}" --out "{{BUILD_DIR}}/AppIcon.iconset/icon_256x256.png"   >/dev/null
    @sips -z 512 512   "{{ICON_SRC}}" --out "{{BUILD_DIR}}/AppIcon.iconset/icon_256x256@2x.png">/dev/null
    @sips -z 512 512   "{{ICON_SRC}}" --out "{{BUILD_DIR}}/AppIcon.iconset/icon_512x512.png"   >/dev/null
    @cp "{{ICON_SRC}}" "{{BUILD_DIR}}/AppIcon.iconset/icon_512x512@2x.png"
    @iconutil -c icns "{{BUILD_DIR}}/AppIcon.iconset" -o "{{ICNS}}"
    @rm -rf "{{BUILD_DIR}}/AppIcon.iconset"

_bundle: _compile _icns
    @echo "→ Assembling {{APP_BUNDLE}}"
    @rm -rf "{{APP_BUNDLE}}"
    @mkdir -p "{{MACOS_DIR}}" "{{RES_DIR}}"
    @cp "{{EXE}}" "{{MACOS_DIR}}/{{EXE_NAME}}"
    @cp "{{INFO_PLIST_SRC}}" "{{CONTENTS}}/Info.plist"
    @cp "{{ICNS}}" "{{RES_DIR}}/AppIcon.icns"
    @cp "{{ICON_SRC}}" "{{RES_DIR}}/MenuBarIcon.png"
    @echo "→ Codesigning"
    @if security find-identity -p codesigning | grep -q "copybara-local"; then \
        echo "   using stable identity: copybara-local"; \
        codesign -s "copybara-local" --force --deep "{{APP_BUNDLE}}" 2>&1 | sed 's/^/   /'; \
    else \
        echo "   (no copybara-local cert found; falling back to ad-hoc — TCC will re-prompt on every build)"; \
        codesign -s - --force --deep "{{APP_BUNDLE}}" 2>&1 | sed 's/^/   /'; \
    fi
    @echo "✓ Built {{APP_BUNDLE}}"
