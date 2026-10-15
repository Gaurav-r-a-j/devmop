import Foundation
import SweepCore

struct Options {
    var command = "scan"
    var roots: [String] = []
    var json = false
    var inactiveDays = 60
    var maxTier: SafetyTier = .rebuildable
    var includeCaches = false
    var permanent = false
    var yes = false
    var limit = 25
}

func usage() -> Never {
    print("""
    sweep — find and clean developer disk space

    USAGE
      sweep scan  [--root PATH]... [--inactive DAYS] [--limit N] [--json]
      sweep clean [--root PATH]... [--inactive DAYS] [--tier safe|rebuildable] [--caches] [--permanent] [--yes]

    clean only prints the plan unless --yes is given. Items go to the Trash unless --permanent is given.
    """)
    exit(0)
}

func parse() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    if let first = arguments.first, !first.hasPrefix("-") {
        options.command = first
        arguments.removeFirst()
    }
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--root": if let value = iterator.next() { options.roots.append((value as NSString).expandingTildeInPath) }
        case "--json": options.json = true
        case "--inactive": options.inactiveDays = iterator.next().flatMap(Int.init) ?? options.inactiveDays
        case "--limit": options.limit = iterator.next().flatMap(Int.init) ?? options.limit
        case "--tier": options.maxTier = iterator.next().flatMap(SafetyTier.init(rawValue:)) ?? options.maxTier
        case "--caches": options.includeCaches = true
        case "--permanent": options.permanent = true
        case "--yes", "-y": options.yes = true
        case "--help", "-h": usage()
        default:
            FileHandle.standardError.write(Data("Unknown option \(argument)\n".utf8))
            exit(2)
        }
    }
    if !["scan", "clean"].contains(options.command) { usage() }
    return options
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? String(text.prefix(width - 1)) + "…" : text + String(repeating: " ", count: width - text.count)
}

func rpad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

func bytes(_ value: Int64) -> String { ByteFormat.string(value) }

func relative(_ date: Date?) -> String {
    guard let date else { return "unknown" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

func printReport(_ result: ScanResult, options: Options) {
    let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m"

    if let disk = result.disk {
        print("\(bold)Disk\(reset)  \(bytes(disk.used)) used of \(bytes(disk.total)), \(bytes(disk.available)) available")
    }
    print("\(bold)Reclaimable\(reset)  \(bytes(result.totalReclaimable))  \(dim)(projects \(bytes(result.projectBytes)), caches \(bytes(result.cacheBytes)), simulators \(bytes(result.simulatorBytes)), docker \(bytes(result.dockerBytes)), system data \(bytes(result.systemBytes)), trash \(bytes(result.trashBytes)))\(reset)")
    let reused = result.measuredCount.map { " — measured \($0) changed folders, reused the rest" } ?? ""
    print("\(dim)Scanned in \(String(format: "%.1f", result.duration))s\(reused)\(reset)\n")

    print("\(bold)\(pad("PROJECT", 34))\(rpad("FREES", 10))  \(pad("LAST ACTIVE", 14))  STATUS\(reset)")
    for project in result.projects.prefix(options.limit) {
        var flags: [String] = []
        if let process = project.runningProcess { flags.append("in use (\(process))") }
        if let git = project.git {
            if git.isWorktree { flags.append("worktree") }
            if git.changedFiles > 0 { flags.append("\(git.changedFiles) changes") }
            if let unpushed = git.unpushedCommits, unpushed > 0 { flags.append("\(unpushed) unpushed") }
        }
        if project.isInactive(days: options.inactiveDays) { flags.append("inactive") }
        print("\(pad(project.name, 34))\(rpad(bytes(project.reclaimable), 10))  \(pad(relative(project.lastActive), 14))  \(flags.joined(separator: ", "))")
        print("  \(dim)\(project.path.abbreviatingHome)\(reset)")
        for group in project.artifactGroups {
            let shared = group.reclaimable < group.allocated / 2 ? " of \(bytes(group.allocated))" : ""
            let note = group.blockedReason ?? group.warning ?? ""
            let label = group.folderName + (group.artifacts.count > 1 ? " ×\(group.artifacts.count)" : "")
            print("    \(dim)\(pad(label, 30))\(rpad(bytes(group.reclaimable), 10))\(shared)  [\(group.tier.title)] \(note)\(reset)")
        }
        if let worktree = project.worktreeArtifact {
            print("    \(dim)\(pad("whole worktree", 30))\(rpad(bytes(worktree.size.reclaimable), 10))  [\(worktree.tier.title)] \(worktree.blockedReason ?? "can be removed")\(reset)")
        }
    }
    if result.projects.count > options.limit {
        print("\(dim)… \(result.projects.count - options.limit) more projects (use --limit)\(reset)")
    }

    print("\n\(bold)\(pad("CACHE", 34))\(rpad("FREES", 10))  \(pad("TIER", 12))  HOW\(reset)")
    for item in result.caches.sorted(by: { $0.size.reclaimable > $1.size.reclaimable }) {
        let estimate = item.size.isEstimate ? "up to " : ""
        let note = item.blockedReason.map { " — \($0)" } ?? ""
        print("\(pad(item.name, 34))\(rpad(estimate + bytes(item.size.reclaimable), 10))  \(pad(item.tier.title, 12))  \(dim)\(item.methodDescription)\(note)\(reset)")
    }

    if !result.simulators.isEmpty || !result.runtimes.isEmpty {
        print("\n\(bold)SIMULATORS\(reset)")
        for runtime in result.runtimes {
            print("\(pad(runtime.name + " runtime", 34))\(rpad(bytes(runtime.sizeBytes), 10))  \(dim)last used \(relative(runtime.lastUsed))\(runtime.isDeletable ? "" : ", managed by macOS")\(reset)")
        }
        for device in result.simulators where device.size.reclaimable > 50_000_000 {
            print("\(pad("\(device.name) · \(device.runtime)", 34))\(rpad(bytes(device.size.reclaimable), 10))  \(dim)\(device.state.lowercased()), last booted \(relative(device.lastBooted))\(reset)")
        }
    }

    if let files = result.files, !files.isEmpty {
        print("\n\(bold)YOUR FILES\(reset)  \(dim)(review only, always moved to the Trash)\(reset)")
        for reason in UserFileReason.allCases {
            let matching = files.filter { $0.reasons.contains(reason) }
            guard !matching.isEmpty else { continue }
            let total = matching.reduce(0) { $0 + $1.reclaimable }
            print("\(pad(reason.title, 34))\(rpad(bytes(total), 10))  \(dim)\(matching.count) files\(reset)")
        }
    }

    if let apps = result.apps, !apps.isEmpty {
        print("\n\(bold)APPS\(reset)  \(dim)\(apps.count) installed, \(result.orphans?.count ?? 0) with leftovers from deleted apps\(reset)")
        for app in apps.prefix(8) {
            print("\(pad(app.name, 34))\(rpad(bytes(app.totalReclaimable), 10))  \(dim)\(app.leftovers.count) leftovers, last used \(relative(app.lastUsed))\(reset)")
        }
        for orphan in (result.orphans ?? []).prefix(5) {
            print("\(pad("leftover: " + orphan.bundleID, 34))\(rpad(bytes(orphan.reclaimable), 10))")
        }
    }

    if result.dockerRunning == false { print("\n\(dim)Docker is installed but not running.\(reset)") }
    if result.hasLocalSnapshots { print("\n\(dim)Time Machine local snapshots exist; macOS frees deleted space gradually.\(reset)") }
    if !result.hasFullDiskAccess { print("\n\(dim)Full Disk Access is off for this terminal; some Library folders may be skipped.\(reset)") }
}

func run() async {
    let options = parse()
    var settings = SweepSettings(inactiveDays: options.inactiveDays, deleteMode: options.permanent ? .permanent : .trash)
    if !options.roots.isEmpty { settings.roots = options.roots }

    let interactive = isatty(STDERR_FILENO) == 1 && !options.json
    let usesDefaultRoots = options.roots.isEmpty
    let previous = usesDefaultRoots ? ScanCache.load() : nil
    let result = await Scanner(settings: settings).scan(previous: previous) { progress in
        guard interactive, progress.phase != .done else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(String(progress.message.prefix(100)))".utf8))
    }
    if interactive { FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8)) }
    if usesDefaultRoots { ScanCache.save(result) }

    if options.command == "scan" {
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try! encoder.encode(result))
        } else {
            printReport(result, options: options)
        }
        return
    }

    var targets: [CleanTarget] = []
    for project in result.projects where project.isInactive(days: options.inactiveDays) {
        for artifact in project.artifacts where artifact.kind == .folder && artifact.tier <= options.maxTier && artifact.blockedReason == nil {
            targets.append(.artifact(artifact, project: project))
        }
    }
    if options.includeCaches {
        targets += result.caches.filter { $0.tier == .safe && $0.isCleanable }.map(CleanTarget.cache)
    }

    let total = targets.reduce(0) { $0 + $1.bytes }
    print("Plan: \(targets.count) items, about \(bytes(total)) (\(settings.deleteMode.title.lowercased()))\n")
    for target in targets {
        print("  \(pad(target.title, 50))\(rpad(bytes(target.bytes), 10))  [\(target.tier.title)]")
    }
    guard options.yes else {
        print("\nNothing deleted. Run again with --yes to clean.")
        return
    }

    let count = targets.count
    let report = await Cleaner.clean(targets, mode: settings.deleteMode) { index, target in
        print("[\(index + 1)/\(count)] \(target.title)")
    }
    print("\nCleaned \(bytes(report.cleanedBytes)). Disk free space grew by \(bytes(report.diskFreedBytes)).")
    if report.mode == .trash, report.trashedBytes > 0 {
        print("\(bytes(report.trashedBytes)) is in the Trash; empty it to free that space.")
    }
    for failure in report.failures {
        print("  ✗ \(failure.title): \(failure.message ?? "failed")")
    }
}

let done = DispatchSemaphore(value: 0)
Task {
    await run()
    done.signal()
}
done.wait()
