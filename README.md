# DevMop

A native macOS app that shows where your disk space goes and safely frees what you don't need — built first for developers, useful for every Mac.

- **Developer clean-up:** `node_modules`, `.next`, `dist`, `target`, `.venv` and other build folders per project, package-manager caches (npm, pnpm, Yarn, Bun, Homebrew, CocoaPods, Gradle, Cargo, pip…), Xcode DerivedData, simulators and runtimes, Docker, AI models, old Node versions and obsolete editor extensions.
- **System Data:** iPhone/iPad backups, Time Machine local snapshots, iOS update files, leftover macOS installers, logs, Mail attachment copies, app and browser caches, and iCloud Drive downloads that are already safe in iCloud.
- **Your files:** large and old files, leftover installers and extracted archives in Downloads, and exact duplicates.
- **Apps:** uninstall apps with their caches and settings, and remove data left behind by apps you already deleted.
- **Storage Map:** every part of the disk — your folders, Library, Homebrew, macOS itself — with what it is and whether it can be cleaned.

## Install

Download the latest DMG from Releases, open it and drag DevMop to Applications. Then give it **Full Disk Access** in System Settings › Privacy & Security, so it can measure Library, Mail, Photos and the Trash.

To build from source (macOS 14+, Xcode 16+):

```sh
make install      # build, install to /Applications and open
make help         # every command
```

## What DevMop deletes — and never deletes

Nothing is deleted until you review the list and confirm. Every item is checked again right before it's removed.

| Tier | Meaning | Examples |
|---|---|---|
| Safe | Pure cache, recreated automatically | npm/pnpm/Yarn/Bun caches, DerivedData, `.turbo`, browser caches |
| Rebuildable | Needs a reinstall, rebuild or download | `node_modules`, `.next`, `target`, `.venv`, simulators, iCloud downloads |
| Review | May hold data; never selected for you | backups, Docker volumes, worktrees, AI models, your files, apps and their data |
| Protected | Never offered | `.git`, source code, `.env`, your home and Library folders themselves, iCloud and Dropbox folders, macOS |

- Folders like `dist` and `build` only count when git ignores them. Worktrees are removable only when clean and fully merged.
- Your files and apps always go to the Trash. The last copy of a duplicate is always kept.
- Read-only, locked or other users' files are left in place and reported.
- Projects with a running dev server, and apps that are open, are skipped.
- Tools are cleaned with their own commands (`pnpm store prune`, `docker builder prune`, `xcrun simctl delete`), run from an empty folder.

## Privacy

Nothing leaves your Mac. DevMop has no analytics, no accounts and makes no network requests. See [PRIVACY.md](PRIVACY.md).

## Uninstall DevMop

1. Quit it from the menu bar icon.
2. Turn off **Open at login** in its Settings, and remove it from Full Disk Access.
3. Move DevMop to the Trash, then remove its data:

```sh
rm -rf ~/Library/Application\ Support/DevMop
defaults delete app.devmop.DevMop
```

## Command line

```sh
make cli
build/mop scan                                 # report, nothing is deleted
build/mop clean --inactive 90                  # show what would be cleaned
build/mop clean --inactive 90 --caches --yes   # clean it (to the Trash)
```

## Development

```sh
make build        # compile
make test         # 100+ tests; fixtures live in temp folders only
make run          # build the app and open it from build/
make icon         # preview the generated app icon
```

Layout: `Sources/SweepCore` (scanner, rules, safety checks, cleaner), `Sources/mop` (CLI), `Sources/DevMop` (SwiftUI app), `Tests/SweepCoreTests`.

## Website

The site lives in `docs/` as plain HTML and CSS, with no build step. Preview it with `make site`.

To publish it on GitHub Pages: push the repository, then in **Settings › Pages** choose **Deploy from a branch**, branch `main`, folder `/docs`. Replace `YOUR-USERNAME` in `docs/index.html` with your GitHub user or organisation so the Download and GitHub links work.

## Releasing

One-time setup with an Apple Developer account:

```sh
xcrun notarytool store-credentials devmop-notary --apple-id you@example.com --team-id TEAMID
```

Each release:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make release VERSION=1.0.0
```

This runs the tests, builds a universal app with Hardened Runtime, notarizes and staples the app and the DMG, checks them with Gatekeeper, archives the dSYMs, and prints the DMG's SHA-256. DevMop can't ship on the Mac App Store because the sandbox blocks the folder access a cleaner needs.
