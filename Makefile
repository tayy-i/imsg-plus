SHELL := /bin/bash

.PHONY: help format lint test build imsg-plus clean build-dylib build-helper install uninstall

help:
	@printf "%s\n" \
		"make format     - swift format in-place" \
		"make lint       - swift format lint + swiftlint" \
		"make test       - sync version, patch deps, run swift test" \
		"make build      - universal release build into bin/" \
		"make build-dylib - build injectable dylib for Messages.app" \
		"make imsg-plus  - clean rebuild + run debug binary (ARGS=...)" \
		"make install    - build release binary and install to /usr/local/bin" \
		"make uninstall  - remove installed binary from /usr/local/bin" \
		"make clean      - swift package clean"

format:
	swift format --in-place --recursive Sources Tests

lint:
	swift format lint --recursive Sources Tests
	swiftlint

test:
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift test

build: build-dylib
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	scripts/build-universal.sh

# Build injectable dylib for Messages.app (DYLD_INSERT_LIBRARIES)
# Uses arm64e architecture to match Messages.app on Apple Silicon
build-dylib:
	@echo "Building imsg-plus-helper.dylib (injectable)..."
	@mkdir -p .build/release
	@clang -dynamiclib -arch arm64e -fobjc-arc \
		-framework Foundation \
		-o .build/release/imsg-plus-helper.dylib \
		Sources/IMsgHelper/IMsgInjected.m
	@echo "Built imsg-plus-helper.dylib successfully"
	@echo "To test manually:"
	@echo "  killall Messages 2>/dev/null; sleep 1"
	@echo "  DYLD_INSERT_LIBRARIES=.build/release/imsg-plus-helper.dylib /System/Applications/Messages.app/Contents/MacOS/Messages &"

# Legacy standalone helper (kept for backward compatibility)
build-helper:
	@echo "Building imsg-helper (standalone, Objective-C)..."
	@mkdir -p .build/release
	@clang -fobjc-arc -framework Foundation -o .build/release/imsg-helper Sources/IMsgHelper/main.m
	@echo "Built imsg-helper successfully"

imsg-plus: build-dylib
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift package clean
	swift build -c debug --product imsg-plus
	./.build/debug/imsg-plus $(ARGS)

clean:
	swift package clean
	@rm -f .build/release/imsg-plus-helper.dylib
	@rm -f .build/release/imsg-helper

install: build-dylib
	@echo "Building release binary..."
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift build -c release --product imsg-plus
	@echo "Installing imsg-plus to /usr/local/bin..."
	@mkdir -p /usr/local/bin /usr/local/lib
	@cp .build/release/imsg-plus /usr/local/bin/imsg-plus
	@cp .build/release/imsg-plus-helper.dylib /usr/local/lib/imsg-plus-helper.dylib
	@echo "Re-signing binaries (required after copy to avoid macOS killing them)..."
	@codesign -f -s - /usr/local/bin/imsg-plus
	@codesign -f -s - /usr/local/lib/imsg-plus-helper.dylib
	@echo "✅ Installed! You can now run 'imsg-plus' from anywhere"
	@echo ""
	@echo "To enable advanced features (typing, read receipts, tapbacks):"
	@echo "  1. Disable SIP (System Integrity Protection)"
	@echo "  2. Launch Messages with injection: imsg-plus launch"

uninstall:
	@echo "Removing imsg-plus from /usr/local/bin..."
	@rm -f /usr/local/bin/imsg-plus
	@echo "✅ Uninstalled"
