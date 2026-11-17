.PHONY: build release clean

CURRENT_VERSION := $(shell /usr/bin/plutil -extract CFBundleShortVersionString raw Info.plist)

# system actool path (nix shell's xcrun can't find it)
ACTOOL := /Applications/Xcode.app/Contents/Developer/usr/bin/actool

APP := dist/pinky.app
SOURCES := $(wildcard src/*.m src/*.c)
CFLAGS := -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=14.0
FRAMEWORKS := -framework Foundation -framework AppKit -framework ApplicationServices -framework IOKit

build:
	rm -rf dist
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	$(CC) $(CFLAGS) -DPINKY_VERSION='"$(CURRENT_VERSION)"' -o $(APP)/Contents/MacOS/pinky $(SOURCES) $(FRAMEWORKS)
	cp Info.plist $(APP)/Contents/Info.plist
	if [ -d pinky.icon ]; then \
		$(ACTOOL) pinky.icon \
			--compile $(APP)/Contents/Resources \
			--app-icon pinky \
			--include-all-app-icons \
			--output-partial-info-plist dist/actool.plist \
			--output-format human-readable-text \
			--platform macosx \
			--target-device mac \
			--minimum-deployment-target 26.0 \
			--enable-on-demand-resources NO \
			--development-region en \
			--notices --warnings --errors > /dev/null && \
		rm dist/actool.plist; \
	fi
	codesign --force --sign "$${CODESIGN_IDENTITY:--}" $(APP)

release:
	@if [ -z "$$CODESIGN_IDENTITY" ]; then \
		echo "error: CODESIGN_IDENTITY not set - release builds require signing"; \
		echo "hint: enter the devShell (direnv allow) to auto-detect your Apple Development cert"; \
		exit 1; \
	fi
	@printf "current version: $(CURRENT_VERSION)\nnew version: "; \
	read VERSION; \
	if [ -z "$$VERSION" ]; then echo "error: no version provided"; exit 1; fi; \
	sed -i"" "s|version = \".*\";|version = \"$$VERSION\";|" flake.nix; \
	/usr/bin/plutil -replace CFBundleVersion -string "$$VERSION" Info.plist; \
	/usr/bin/plutil -replace CFBundleShortVersionString -string "$$VERSION" Info.plist; \
	$(MAKE) build || exit 1; \
	TARBALL="pinky-$$VERSION-aarch64-darwin.tar.gz"; \
	tar -czf "$$TARBALL" -C dist pinky.app; \
	HASH=$$(nix hash file --type sha256 --sri "$$TARBALL"); \
	sed -i"" "s|hash = \".*\";|hash = \"$$HASH\";|" flake.nix; \
	echo "built $$TARBALL"; \
	echo "hash: $$HASH (updated in flake.nix)"; \
	echo "next: commit, gh release create v$$VERSION $$TARBALL, push"

clean:
	rm -rf dist *.tar.gz
