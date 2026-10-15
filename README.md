# DevSweep

A native macOS app that finds the disk space developer tools waste — `node_modules`, build outputs, package-manager caches, Docker, Xcode simulators and stale git worktrees — and lets you clean it safely.

- **Project-aware.** Groups build folders by project and shows when you last worked on each, its git state, and whether something is running in it.
- **Honest sizes.** Measures what deleting actually frees. pnpm and APFS clones share files, so a 2.4 GB `node_modules` may free only 48 MB; DevSweep shows the real number.
- **Safe by design.** Never touches `.git`, source or `.env` files. Generic folders like `dist` and `build` only count when git ignores them. Worktrees are removable only when clean and fully merged. Everything goes to the Trash by default.
- **Uses each tool's own cleaner** — `pnpm store prune`, `npm cache clean`, `docker builder prune`, `xcrun simctl delete` — instead of deleting their files directly.

## Requirements

macOS 14 or later. Building needs Xcode 16 or later (Swift 6).

## Build

```sh
./scripts/build-app.sh          # build/DevSweep.app and build/sweep (universal, ad-hoc signed)
open build/DevSweep.app
```

Give DevSweep **Full Disk Access** (System Settings › Privacy & Security) so it can measure caches inside `~/Library`.

## Command line

```sh
build/sweep scan                         # report, nothing is deleted
build/sweep scan --root ~/code --json    # one folder, machine-readable
build/sweep clean --inactive 90          # show what would be cleaned
build/sweep clean --inactive 90 --caches --yes   # clean it (to the Trash)
```

## Safety tiers

| Tier | Meaning | Examples |
|---|---|---|
| Safe | Pure cache, recreated automatically | npm/pnpm/yarn/bun caches, DerivedData, `.turbo` |
| Rebuildable | Needs a reinstall or rebuild | `node_modules`, `.next`, `target`, `.venv`, simulators |
| Review | May hold data; never preselected | Docker volumes, Android emulators, worktrees, Xcode archives |
| Protected | Never offered | `.git`, source files, `.env`, iCloud Drive |

## Development

```sh
swift build
swift test                # 59 tests; fixtures live in temp folders only
```

Layout: `Sources/SweepCore` (scanner, rules, safety checks, cleaner), `Sources/sweep` (CLI), `Sources/DevSweep` (SwiftUI app), `Tests/SweepCoreTests`.

## Releasing

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" VERSION=1.0.0 ./scripts/build-app.sh
ditto -c -k --keepParent build/DevSweep.app build/DevSweep.zip
xcrun notarytool submit build/DevSweep.zip --keychain-profile notary --wait
xcrun stapler staple build/DevSweep.app
```

Notarization needs an Apple Developer account. The app can't ship on the Mac App Store because the sandbox blocks the folder access it needs.
