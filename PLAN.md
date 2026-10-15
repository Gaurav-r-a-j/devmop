# DevSweep — a disk cleaner for Mac developers

A Mac app that finds the space developer tools waste (node_modules, build outputs, package-manager caches, Docker, Xcode/simulators, stale git worktrees), shows it per project with "last worked on" context, and lets you pick what to delete — safely.

## 1. Is it possible?

Yes. Everything here uses normal file-system APIs plus each tool's own CLI. No kernel extensions, no private APIs. The only Mac-specific hurdles are:

- **Full Disk Access** — the user grants it once in System Settings so the scanner can read `~/Library/...`. The app detects a missing grant and shows how to enable it.
- **Notarization** — needed only to share the app with others without a Gatekeeper warning (Apple Developer account, $99/yr). For personal use, not needed.

## 2. What this Mac has right now (measured 2026-10-15)

Disk: 460 GB, 348 GB used, 76 GB free.

| Item | Size | Tier |
|---|---|---|
| 309 `node_modules` folders | 47.8 GB* | Rebuildable |
| Docker (`~/Library/Containers/com.docker.docker`) | 30 GB | Review |
| `~/Library/Caches` (all apps) | 23 GB | Mostly safe |
| iOS Simulators (`CoreSimulator`) | 22 GB | Rebuildable |
| pnpm store (`~/Library/pnpm` + cache) | 24 GB | Safe via `pnpm store prune` |
| npm cache (`~/.npm`) | 8.6 GB | Safe |
| VS Code / Cursor app data | 11.5 GB | Review (workspace storage, logs) |
| Gradle (`~/.gradle`) | 5.1 GB | Safe |
| Bun (`~/.bun`) | 4.8 GB | Safe (install cache) |
| Android (`~/.android`) | 3.2 GB | Review (AVD images) |
| Yarn, CocoaPods, Playwright, Expo | ~8 GB | Safe |
| Stale Claude agent worktrees | 9.5 GB left | Review (git checks) |

\* pnpm hardlinks files from its store into `node_modules`, so deleting a pnpm project's `node_modules` frees less than its listed size. The app must show the space that **actually gets freed** (see 6.3).

Realistic reclaim without touching anything you need: **80–120 GB**.

## 3. Similar tools and what they are missing

| Tool | Does | Missing |
|---|---|---|
| npkill | Lists and deletes node_modules (CLI) | Node only, no project context, no caches |
| kondo | Cleans build outputs for many languages (CLI) | No caches, Docker, Xcode or git checks |
| DevCleaner for Xcode | Xcode data only | Everything else |
| CleanMyMac / DaisyDisk | General cleaning and size view | Doesn't understand projects; can't tell a live repo from a dead one |

**What this app adds:** it understands projects across languages, knows how each tool should be cleaned, checks git before deleting anything, and shows the space you will actually get back.

## 4. Safety tiers (the core rule)

Every item the app finds gets one tier. The UI, defaults and auto mode follow it.

| Tier | Meaning | Examples | Default |
|---|---|---|---|
| **Safe** | Pure cache; tools rebuild it on their own | npm/yarn/bun/pnpm caches, Gradle caches, Homebrew cache, DerivedData, `__pycache__`, `.next/cache`, `.turbo`, Playwright old browsers | Preselected |
| **Rebuildable** | Deleting it means a reinstall or rebuild in that project | `node_modules`, `dist`, `build`, `.next`, `Pods`, Rust `target`, `.venv`, simulators, Xcode DeviceSupport | Preselected only when the project is inactive longer than N days |
| **Review** | Might hold data or work | Docker volumes/images, Android AVDs, git worktrees, VS Code `workspaceStorage`, Archives | Never preselected; shows why |
| **Protected** | Never offered for deletion | `.git` folders, source files, `.env*`, keychains, SSH keys, `~/Library/Mobile Documents` (iCloud), Photos/Mail libraries | Hidden or read-only |

**About `.git`:** deleting a `.git` folder destroys history and any unpushed work, so it is **Protected**. To shrink git safely, the app instead offers:

- `git gc --prune=now`
- removing stale worktrees (the check done manually today: clean tree, no commits missing from main, not in use by a process)
- deleting branches that are fully merged
- showing oversized repos so you can decide yourself

## 5. Features

### 5.1 Projects view (main screen)
- Finds projects by looking for marker files: `package.json`, `pnpm-workspace.yaml`, `Cargo.toml`, `pyproject.toml`, `Podfile`, `build.gradle`, `*.xcodeproj`, `go.mod`, `.git`.
- Groups monorepos: workspace packages appear under their root as one row that expands.
- Each row shows:
  - project name and path
  - **last active**: newest of (last commit, newest source-file change outside build folders, last time opened in VS Code/Cursor from their recent-workspaces data)
  - git state: uncommitted changes, unpushed commits, worktree count
  - each artifact (node_modules, .next, dist…) with listed size and actually-freed size, plus a checkbox
- Filters: "inactive > 30/60/90 days", by language, by size, by folder.
- Select all inactive projects, or pick individual folders.

### 5.2 Global caches view
- Shows each cache with its size, tier, and **how** it will be cleaned.
- Prefers the tool's own command over deleting files:

| Cache | Command |
|---|---|
| pnpm | `pnpm store prune` |
| npm | `npm cache clean --force` |
| yarn | `yarn cache clean` |
| bun | `bun pm cache rm` |
| Homebrew | `brew cleanup -s` |
| Simulators | `xcrun simctl delete unavailable`, and an option to delete runtimes you don't use |
| Docker | `docker system df` for the breakdown, then a choice between `docker image prune`, `docker builder prune`, `docker container prune` |

  Docker volumes are listed separately and are never pruned by default.
- Falls back to deleting files only when the tool isn't installed.

### 5.3 Editor and agent leftovers
- VS Code / Cursor `workspaceStorage` entries whose project folder no longer exists
- old extension versions in `~/.vscode/extensions`
- logs
- `.claude/worktrees` checked with the same git rules as 4

### 5.4 Deletion
- **Default: move to Trash.** Moving within the same disk is a rename, so it's instant and can be undone. A "Delete permanently" toggle is available for big cleanups.
- A confirmation sheet lists everything selected and the total freed, and calls out anything in the Review tier.
- Every run writes a log (path, size, time, how to rebuild, e.g. "run `pnpm install` in X"). A **History** tab shows past runs.

### 5.5 Auto mode (optional, later phase)
- Menu-bar app plus a weekly scheduled scan.
- Sends a notification: "38 GB reclaimable in 12 inactive projects", which opens the preview.
- Without asking, it only ever cleans the **Safe** tier. Rebuildable and Review items always need a click.

## 6. Edge cases the app must handle

### 6.1 Never break active work
- Skip a project that is currently in use: check whether any running process has its working directory or open files inside it (the `lsof` / `proc_pidinfo` style of check — Expo, a tsx watch process, an editor window).
- Skip a worktree that is locked, has uncommitted changes, or has commits not in its base branch. Use patch-equivalence (`git cherry`), not merge ancestry, so squash-merged branches are recognised.
- Warn before deleting `node_modules` from a project that has **no lockfile**, because the reinstall may resolve different versions.
- Docker: stop if the daemon isn't running. Never touch volumes unless they are selected one by one.
- Simulators: skip simulators that are booted.

### 6.2 File-system traps
- **Never follow symlinks** during scan or delete. pnpm and monorepos use them heavily, and following one can lead outside the project.
- Don't descend into `node_modules` after finding it (size it, don't treat nested ones as separate items).
- **iCloud Drive and "Optimize Storage" folders:** skip `~/Library/Mobile Documents` and any file iCloud has offloaded. Reading those triggers downloads.
- External and network drives: off by default, opt-in for each drive.
- Permission errors and SIP-protected paths: record them as "couldn't read", never crash.
- Very long paths, odd filename characters, case-insensitive name clashes.
- A file removed or changed between scan and delete: re-check each path and its size right before deleting.

### 6.3 Showing the space actually freed
- **Hardlinks (pnpm):** count a file as freed only when nothing outside the selection still links to it. Track the inode and link count of each file during the scan.
- **APFS clones** share disk blocks and can't be detected cheaply, so mark sizes as "estimated" where clones are likely.
- **Time Machine local snapshots** keep deleted files until macOS thins them. After a cleanup, tell the user if snapshots exist (`tmutil listlocalsnapshots /`) and offer the macOS command to thin them.
- Trash: space comes back only after emptying it. Show "X GB in Trash" with an Empty button.

### 6.4 Scale
- About 309 node_modules folders and millions of files. Use a parallel directory walk, read file attributes in bulk (`getattrlistbulk`) when sizing, and stream results to the UI as they arrive.
- Cache the scan so the next launch shows the last results right away, then refresh in the background.

## 7. Tech choice: SwiftUI (native Swift)

Mac-only app, so native Swift wins. Comparison with Tauri (Rust + React):

| | SwiftUI + Swift | Tauri + Rust + React |
|---|---|---|
| Scan speed | Same. Disk scanning is limited by system calls, not the language, and Swift calls `getattrlistbulk` / `fts` directly, with parallelism from Swift concurrency (`TaskGroup`). | Same (`jwalk`). No real advantage. |
| Memory while running | Lowest: one process. | Higher: WKWebView runs in separate WebKit helper processes, often 100 MB or more. |
| App size | ~3–6 MB | ~10 MB |
| Mac APIs | Built in: `FileManager.trashItem`, `MenuBarExtra`, `SMAppService` (login item), `UNUserNotificationCenter`, `NSWorkspace`, FSEvents, Full Disk Access checks | Plugins or Rust bridges for each one |
| Languages and toolchains | 1 (Swift + Xcode) | 3 (Rust, TypeScript, Tauri build) and an IPC layer between them |
| Look and feel | Native macOS (sidebar, `Table`, sheets, dark mode, accessibility) | Web UI styled to look like macOS |
| Proven for this job | Pearcleaner, DevCleaner, and many Mac cleaners are SwiftUI | Fine, but no advantage on a single platform |

**Trade-offs to plan for:**
- Needs Xcode and macOS 14 or later as the target.
- SwiftUI `Table` can lag with tens of thousands of rows. Show projects (a few hundred rows) rather than individual files, and fall back to `NSTableView` only if needed.
- Swift has no first-class git library. Call the `git` CLI through `Process` instead, which is simpler and matches the behaviour you get in the terminal.
- `getattrlistbulk` has known bugs on SMB and exFAT volumes. Network and external drives are off by default (6.2) and fall back to `FileManager` there.

### Structure
```
dev-disk-cleaner/
  Package.swift
  Sources/
    SweepCore/   scanner, rules, safety checks, sizing, deletion, run log (no UI, unit-tested)
    sweep/       command-line tool using SweepCore (`sweep scan`, `sweep clean --inactive 60d --tier safe`)
  App/           SwiftUI Xcode app using SweepCore (window + menu bar)
  Rules/         detector definitions (JSON): markers, artifact folders, tier, rebuild hint, clean command
  Tests/SweepCoreTests/
```

Rules are data (JSON, read with `Codable`) so you can add a new ecosystem without code changes, e.g.:
```json
{ "name": "Next.js build", "projectMarker": "next.config.*", "path": ".next",
  "tier": "rebuildable", "rebuild": "next build" }
```

## 8. Phases

| Phase | Deliverable | Rough effort |
|---|---|---|
| 1 | SweepCore + `sweep` CLI (Swift package): project detection, node_modules and build outputs, sizing (with hardlink handling), last-active, git state, JSON report. **Dry run only.** | 3–5 days |
| 2 | Deletion: Trash or permanent, safety re-checks, in-use detection, run log | 2–3 days |
| 3 | SwiftUI app: Projects view, filters, selection, confirmation sheet, history | 4–6 days |
| 4 | Global caches through each tool's command, Docker, Xcode and simulators, editor leftovers, worktrees | 3–4 days |
| 5 | Menu bar (`MenuBarExtra`), weekly scan, notifications, Time Machine snapshot tip, Full Disk Access onboarding | 2–3 days |
| 6 | Optional: signing and notarization, Homebrew cask, auto-update | 1–2 days |

Effort above is for building by hand. When Claude writes the code and you test on real data, expect Phase 1 in about 1 day and phases 1–5 in about 5–8 working days. The slow part becomes checking results against real disks and polishing the UI, not writing code.

### Size estimate (Swift lines of code)

| Part | LOC |
|---|---|
| SweepCore: scanner (`getattrlistbulk`, parallel walk, hardlink tracking) | 600–800 |
| SweepCore: rules engine, project detection, monorepo grouping, last-active | 800–1,000 |
| SweepCore: git checks, in-use detection, cache cleaners, Docker, simulators | 1,000–1,200 |
| SweepCore: deletion, re-checks, run log, scan cache, models | 600–800 |
| `sweep` CLI | 300–400 |
| SwiftUI app: views, view models, menu bar, schedule, notifications, onboarding | 2,600–3,200 |
| Tests and fixture builders | 1,500–2,000 |
| **Total** | **~7,500–9,500** (plus ~400 lines of JSON rules) |

Phase 1 alone is about 2,000 LOC.

Phase 1 is useful on its own as soon as it's done. Run it against this Mac and compare the numbers with section 2.

## 9. Testing
- Fixture trees for each ecosystem, including symlink loops, pnpm hardlinks, nested monorepos, worktrees in different states, and unreadable folders.
- Every delete path runs against a temp folder in tests. The test suite never touches the real home folder.
- A dry-run report is compared against `du` on the fixtures to check the sizes.

## 10. Open decisions
1. ~~Tauri or SwiftUI~~ — decided: SwiftUI.
   Decided defaults: inactive after 60 days, Move to Trash, built for commercial release (Developer ID + notarization).
2. Default "inactive" threshold: 30, 60 or 90 days?
3. Default delete mode: Trash (recommended) or permanent?
4. Personal use only, or published (affects notarization and naming)?
