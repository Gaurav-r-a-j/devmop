# DevSweep — run `make help` to see every command.

VERSION ?= 1.0.0

.PHONY: help build app install run test cli icon release clean

help:
	@echo "make build     Compile everything (debug)"
	@echo "make test      Run the test suite"
	@echo "make app       Build build/DevSweep.app (universal)"
	@echo "make install   Build and install to /Applications, then open it"
	@echo "make run       Build the app and open it from build/"
	@echo "make cli       Build the sweep command-line tool to build/sweep"
	@echo "make icon      Regenerate the app icon preview in build/AppIcon.iconset"
	@echo "make release   Signed, notarized DMG (needs SIGN_IDENTITY and VERSION)"
	@echo "make clean     Remove build output"

build:
	swift build

test:
	swift test

app:
	VERSION=$(VERSION) ./scripts/build-app.sh

install:
	VERSION=$(VERSION) ./scripts/install.sh

run: app
	open build/DevSweep.app

cli: app
	@echo "CLI ready: build/sweep"

icon:
	rm -rf build/AppIcon.iconset
	swift scripts/make-icon.swift build/AppIcon.iconset
	open build/AppIcon.iconset/icon_512x512@2x.png

release:
	VERSION=$(VERSION) ./scripts/release.sh

clean:
	rm -rf build .build
