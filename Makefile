PREFIX ?= $(HOME)/.local
APP = build/NotchCue.app

.PHONY: build install uninstall clean check

# Build the app bundle (the notchcue script also does this on first run).
build:
	@./notchcue --validate --text build-check

# Link the notchcue command into $(PREFIX)/bin (default ~/.local/bin).
install: build
	mkdir -p "$(PREFIX)/bin"
	ln -sf "$(CURDIR)/notchcue" "$(PREFIX)/bin/notchcue"
	@echo "Installed: $(PREFIX)/bin/notchcue"

uninstall:
	rm -f "$(PREFIX)/bin/notchcue"

clean:
	rm -rf build

# Compile only, without signing or launching (used by CI).
check:
	mkdir -p build
	swiftc -O NotchCue.swift -o build/notchcue-check
	./build/notchcue-check --validate --text check
