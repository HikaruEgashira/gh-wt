# Makefile — build, bundle and (optionally) sign the gh-wt-overlay
# components on macOS.
#
#   make helper      → builds gh-wt-mount-overlay (release CLI)
#   make extension   → compiles the FSKit extension into a .fskitmodule
#   make app         → assembles GhWtOverlay.app with the extension inside
#   make sign        → codesign + notarize (needs DEVELOPER_ID env var)
#   make install     → copies the helper into /usr/local/bin and the app
#                       into /Applications
#
# The default target builds everything except sign / install.

UNAME_S := $(shell uname -s)
ifneq ($(UNAME_S),Darwin)
$(error This Makefile only runs on macOS)
endif

BUILD := .build
APP_NAME := GhWtOverlay
APP_BUNDLE := $(BUILD)/$(APP_NAME).app
EXT_NAME := GhWtOverlayExtension
EXT_BUNDLE := $(APP_BUNDLE)/Contents/Library/SystemExtensions/$(EXT_NAME).fskitmodule

SDK := $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC := xcrun --sdk macosx swiftc
PLBUDDY := /usr/libexec/PlistBuddy
CODESIGN := /usr/bin/codesign

DEPLOYMENT_TARGET := 26.0

# Default to a single-arch build matching the host. Release artefacts
# that need to ship universal should build each arch separately and
# lipo them together — swiftc does not produce a fat binary when given
# multiple -target flags in one invocation (the last one wins).
TARGET_ARCH ?= $(shell uname -m)
TARGET_TRIPLE := $(TARGET_ARCH)-apple-macos$(DEPLOYMENT_TARGET)

EXT_SOURCES := $(wildcard Sources/GhWtOverlayExtension/*.swift)
CORE_SOURCES := $(wildcard Sources/OverlayCore/*.swift)
APP_SOURCES := $(wildcard App/*.swift)

.PHONY: all helper extension app sign install clean test

all: helper app

helper:
	swift build -c release --product gh-wt-mount-overlay

# Build the FSKit extension as a loadable bundle. SPM doesn't support this
# bundle layout, so we drive swiftc directly.
extension: $(EXT_BUNDLE)

CORE_LIB_DIR := $(BUILD)/OverlayCore
CORE_LIB := $(CORE_LIB_DIR)/libOverlayCore.a
CORE_SWIFTMODULE := $(CORE_LIB_DIR)/OverlayCore.swiftmodule

$(CORE_LIB) $(CORE_SWIFTMODULE): $(CORE_SOURCES)
	@mkdir -p "$(CORE_LIB_DIR)"
	$(SWIFTC) \
	    -target $(TARGET_TRIPLE) \
	    -parse-as-library \
	    -emit-library -static \
	    -emit-module \
	    -module-name OverlayCore \
	    -emit-module-path "$(CORE_SWIFTMODULE)" \
	    -o "$(CORE_LIB)" \
	    $(CORE_SOURCES)

$(EXT_BUNDLE): $(EXT_SOURCES) $(CORE_LIB) $(CORE_SWIFTMODULE) App/Extension-Info.plist | $(APP_BUNDLE)
	@mkdir -p "$(EXT_BUNDLE)/Contents/MacOS" "$(EXT_BUNDLE)/Contents/Resources"
	$(SWIFTC) \
	    -target $(TARGET_TRIPLE) \
	    -parse-as-library \
	    -emit-executable \
	    -module-name $(EXT_NAME) \
	    -framework FSKit \
	    -framework Foundation \
	    -framework OSLog \
	    -I "$(CORE_LIB_DIR)" \
	    -L "$(CORE_LIB_DIR)" -lOverlayCore \
	    -o "$(EXT_BUNDLE)/Contents/MacOS/$(EXT_NAME)" \
	    $(EXT_SOURCES)
	cp App/Extension-Info.plist "$(EXT_BUNDLE)/Contents/Info.plist"
	$(PLBUDDY) -c "Set :NSExtension:NSExtensionPrincipalClass $(EXT_NAME).GhWtOverlayUnaryExtension" \
	    "$(EXT_BUNDLE)/Contents/Info.plist"

app: $(APP_BUNDLE) extension

$(APP_BUNDLE): $(APP_SOURCES) App/Info.plist
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	$(SWIFTC) \
	    -target $(TARGET_TRIPLE) \
	    -parse-as-library \
	    -emit-executable \
	    -module-name $(APP_NAME)App \
	    -framework SwiftUI \
	    -framework SystemExtensions \
	    -framework AppKit \
	    -o "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)App" \
	    $(APP_SOURCES)
	cp App/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"

sign: app
	@if [ -z "$(DEVELOPER_ID)" ]; then \
	    echo "set DEVELOPER_ID=\"Developer ID Application: Name (TEAMID)\""; exit 1; \
	fi
	$(CODESIGN) --force --sign "$(DEVELOPER_ID)" \
	    --entitlements App/Extension.entitlements \
	    --options runtime --timestamp \
	    "$(EXT_BUNDLE)"
	$(CODESIGN) --force --sign "$(DEVELOPER_ID)" \
	    --entitlements App/GhWtOverlay.entitlements \
	    --options runtime --timestamp \
	    "$(APP_BUNDLE)"

install: helper app
	install -m 0755 .build/release/gh-wt-mount-overlay /usr/local/bin/gh-wt-mount-overlay
	rm -rf /Applications/$(APP_NAME).app
	cp -R "$(APP_BUNDLE)" /Applications/

test:
	swift test

clean:
	swift package clean
	rm -rf $(BUILD)
