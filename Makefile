# DevMop — run `make help` to see every command.

VERSION ?= 1.0.0
REPO ?= Gaurav-r-a-j/devmop

.PHONY: help build app install run test cli icon site og stats release clean

help:
	@echo "make build     Compile everything (debug)"
	@echo "make test      Run the test suite"
	@echo "make app       Build build/DevMop.app (universal)"
	@echo "make install   Build and install to /Applications, then open it"
	@echo "make run       Build the app and open it from build/"
	@echo "make cli       Build the mop command-line tool to build/mop"
	@echo "make icon      Regenerate the app icon preview in build/AppIcon.iconset"
	@echo "make site      Open the website (docs/) in your browser"
	@echo "make og        Re-render the link preview image docs/assets/og.png"
	@echo "make stats     Download counts per release from GitHub (needs gh)"
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
	open build/DevMop.app

cli: app
	@echo "CLI ready: build/mop"

icon:
	rm -rf build/AppIcon.iconset
	swift scripts/make-icon.swift build/AppIcon.iconset
	open build/AppIcon.iconset/icon_512x512@2x.png

site:
	open docs/index.html

og:
	"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
		--window-size=1200,630 --force-prefers-reduced-motion --screenshot="$(CURDIR)/docs/assets/og.png" "file://$(CURDIR)/scripts/og-card.html"

stats:
	@gh api repos/$(REPO)/releases --jq '.[] | .tag_name as $$v | .assets[] | "\($$v)  \(.name)  \(.download_count) downloads"'

release:
	VERSION=$(VERSION) ./scripts/release.sh

clean:
	rm -rf build .build
