PREFIX ?= $(HOME)/.local
APPDIR ?= $(HOME)/Applications
APP = build/NotchCue.app
SOURCES = $(wildcard Sources/*.swift)
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: build install uninstall clean check test

# Build the app bundle (the notchcue script also does this on first run).
build:
	@./notchcue --validate --text build-check

# Copy NotchCue.app into ~/Applications (so Spotlight and Launchpad find it)
# and link the notchcue command into $(PREFIX)/bin (default ~/.local/bin).
install: build
	mkdir -p "$(APPDIR)" "$(PREFIX)/bin"
	rm -rf "$(APPDIR)/NotchCue.app"
	ditto "$(APP)" "$(APPDIR)/NotchCue.app"
	touch "$(APPDIR)/NotchCue.app/Contents/.notchcue-install"
	-$(LSREGISTER) -f "$(APPDIR)/NotchCue.app" 2>/dev/null
	ln -sf "$(CURDIR)/notchcue" "$(PREFIX)/bin/notchcue"
	@echo "Installed: $(APPDIR)/NotchCue.app and $(PREFIX)/bin/notchcue"

uninstall:
	rm -f "$(PREFIX)/bin/notchcue"
	rm -rf "$(APPDIR)/NotchCue.app"

clean:
	rm -rf build

# Compile and run the built-in tests, without signing or launching (used by CI).
check:
	mkdir -p build
	swiftc -O $(SOURCES) -o build/notchcue-check
	./build/notchcue-check --self-test
	./build/notchcue-check --validate --text check

test: check
