import Darwin
import Foundation

public enum CleanTarget: Identifiable, Hashable, Sendable {
    case artifact(Artifact, project: Project)
    case cache(CacheItem)
    case simulator(SimulatorDevice)
    case runtime(SimulatorRuntime)
    case file(UserFile)
    case app(InstalledApp)
    case appData(InstalledApp)
    case orphan(OrphanedAppData)

    public var id: String {
        switch self {
        case .artifact(let artifact, _): "artifact:\(artifact.path)"
        case .cache(let item): "cache:\(item.id)"
        case .simulator(let device): "simulator:\(device.udid)"
        case .runtime(let runtime): "runtime:\(runtime.id)"
        case .file(let file): "file:\(file.path)"
        case .app(let app): "app:\(app.path)"
        case .appData(let app): "appdata:\(app.path)"
        case .orphan(let orphan): "orphan:\(orphan.bundleID)"
        }
    }

    public var title: String {
        switch self {
        case .artifact(let artifact, let project):
            artifact.kind == .worktree ? "\(project.name) worktree" : "\(project.name) › \(artifact.folderName)"
        case .cache(let item): item.name
        case .simulator(let device): "\(device.name) (\(device.runtime))"
        case .runtime(let runtime): "\(runtime.name) runtime"
        case .file(let file): file.name
        case .app(let app): "Uninstall \(app.name)"
        case .appData(let app): "\(app.name) app data"
        case .orphan(let orphan): "Leftovers of \(orphan.name)"
        }
    }

    public var bytes: Int64 {
        switch self {
        case .artifact(let artifact, _): artifact.size.reclaimable
        case .cache(let item): item.size.reclaimable
        case .simulator(let device): device.size.reclaimable
        case .runtime(let runtime): runtime.sizeBytes
        case .file(let file): file.reclaimable
        case .app(let app): app.uninstallBytes
        case .appData(let app): app.dataBytes
        case .orphan(let orphan): orphan.reclaimable
        }
    }

    public var tier: SafetyTier {
        switch self {
        case .artifact(let artifact, _): artifact.tier
        case .cache(let item): item.tier
        case .simulator, .runtime: .rebuildable
        case .file, .app, .appData, .orphan: .review
        }
    }

    public var path: String? {
        switch self {
        case .artifact(let artifact, _): artifact.path
        case .cache(let item): item.paths.first
        case .simulator(let device): device.path
        case .runtime: nil
        case .file(let file): file.path
        case .app(let app), .appData(let app): app.path
        case .orphan(let orphan): orphan.leftovers.first?.path
        }
    }

    public var rebuildHint: String? {
        switch self {
        case .artifact(let artifact, _): artifact.rebuildHint
        case .cache: nil
        case .simulator: "Create it again in Xcode › Devices and Simulators"
        case .runtime: "Download it again in Xcode › Settings › Components"
        case .file, .app, .appData, .orphan: "Put it back from the Trash if you need it"
        }
    }

    public var blockedReason: String? {
        switch self {
        case .artifact(let artifact, _): artifact.blockedReason
        case .cache(let item): item.blockedReason
        case .simulator(let device): device.isBooted ? "Running. Shut it down first." : nil
        case .runtime(let runtime): runtime.isDeletable ? nil : "macOS manages this runtime"
        case .file, .orphan: nil
        case .app(let app), .appData(let app): app.blockedReason
        }
    }

    /// Whether deletion goes through the Trash (commands always delete directly).
    public func usesTrash(_ mode: DeleteMode) -> Bool {
        switch self {
        case .file, .app, .appData, .orphan: return true
        case .artifact(let artifact, _) where artifact.kind == .worktree: return true
        default: break
        }
        guard mode == .trash else { return false }
        switch self {
        case .artifact(let artifact, _): return artifact.kind == .folder || artifact.kind == .worktree
        case .cache(let item):
            if item.id == CacheCatalog.trashID { return false }
            switch item.effectiveMethod {
            case .command, .evictDownloads: return false
            default: return true
            }
        case .simulator, .runtime: return false
        case .file, .app, .appData, .orphan: return true
        }
    }
}

public struct CleanOutcome: Codable, Hashable, Sendable, Identifiable {
    public var id: String { targetID }
    public let targetID: String
    public let title: String
    public let path: String?
    /// Bytes removed (freed now plus moved to the Trash), measured before and after.
    public let bytes: Int64
    public let succeeded: Bool
    public let message: String?
    public let rebuildHint: String?
    public let trashedPaths: [String]
    public let freedBytes: Int64?
    public let trashedBytes: Int64?
    /// Files or folders left in place because they are read-only, locked or owned by another user.
    public let skippedItems: Int?
    /// Device and inode of each trashed item, so emptying never removes something else with the same name.
    public var trashedIdentities: [String]? = nil

    public var freedNow: Int64 { freedBytes ?? (trashedPaths.isEmpty ? bytes : 0) }
    public var movedToTrash: Int64 { trashedBytes ?? (trashedPaths.isEmpty ? 0 : bytes) }
    public var isPartial: Bool { succeeded && (skippedItems ?? 0) > 0 }
}

public struct CleanReport: Codable, Hashable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let mode: DeleteMode
    public var outcomes: [CleanOutcome]
    public var diskFreedBytes: Int64

    public var cleanedBytes: Int64 { outcomes.filter(\.succeeded).reduce(0) { $0 + $1.bytes } }
    public var freedBytes: Int64 { outcomes.filter(\.succeeded).reduce(0) { $0 + $1.freedNow } }
    public var trashedBytes: Int64 { outcomes.filter(\.succeeded).reduce(0) { $0 + $1.movedToTrash } }
    public var failures: [CleanOutcome] { outcomes.filter { !$0.succeeded } }
    public var partials: [CleanOutcome] { outcomes.filter(\.isPartial) }
    public var trashedPaths: [String] { outcomes.flatMap(\.trashedPaths) }
}

public enum Cleaner {
    public static func clean(_ targets: [CleanTarget], mode: DeleteMode, progress: (@Sendable (Int, CleanTarget) -> Void)? = nil) async -> CleanReport {
        let before = SystemInfo.disk()?.available ?? 0
        var report = CleanReport(date: Date(), mode: mode, outcomes: [], diskFreedBytes: 0)

        let batchFiles = Set(targets.compactMap { target -> String? in
            if case .file(let file) = target { return file.path }
            return nil
        })
        var removedWorktrees: [String] = []
        for (index, target) in ordered(targets).enumerated() {
            if case .artifact(let artifact, _) = target, artifact.kind == .folder,
               removedWorktrees.contains(where: { artifact.path.isInside($0) }) {
                continue
            }
            progress?(index, target)
            let outcome = await offload { clean(target, mode: mode, batchFiles: batchFiles) }
            report.outcomes.append(outcome)
            if outcome.succeeded, case .artifact(let artifact, _) = target, artifact.kind == .worktree {
                removedWorktrees.append(artifact.path)
            }
        }

        let after = SystemInfo.disk()?.available ?? 0
        report.diskFreedBytes = max(0, after - before)
        History.append(report)
        return report
    }

    /// Permanently removes items a cleanup moved to the Trash, only if each is still the exact item that was moved.
    public static func emptyFromTrash(_ report: CleanReport) -> (removed: Int, freed: Int64, skipped: Int) {
        var items: [(path: String, identity: String?)] = []
        for outcome in report.outcomes {
            let identities = outcome.trashedIdentities ?? []
            for (index, path) in outcome.trashedPaths.enumerated() {
                items.append((path, index < identities.count ? identities[index] : nil))
            }
        }
        return emptyFromTrash(items)
    }

    static func emptyFromTrash(_ items: [(path: String, identity: String?)]) -> (removed: Int, freed: Int64, skipped: Int) {
        var removed = 0
        var freed: Int64 = 0
        var skipped = 0
        let trash = SystemInfo.trashPath
        for item in items {
            let path = (item.path as NSString).standardizingPath
            guard path.isInside(trash), path.lowercased() != trash.lowercased() else { continue }
            guard let expected = item.identity, !expected.isEmpty, identity(of: path) == expected else {
                skipped += 1
                continue
            }
            let result = Remover.remove(path)
            freed += result.freed
            skipped += result.skipped
            if result.skipped == 0 { removed += 1 }
        }
        return (removed, freed, skipped)
    }

    /// Permanently deletes items from the Trash and records the run in History.
    public static func deleteFromTrash(_ entries: [TrashEntry]) async -> CleanReport {
        let before = SystemInfo.disk()?.available ?? 0
        var report = CleanReport(date: Date(), mode: .permanent, outcomes: [], diskFreedBytes: 0)
        let trash = SystemInfo.trashPath
        for entry in entries {
            let path = (entry.path as NSString).standardizingPath
            guard path.isInside(trash), path != trash else { continue }
            let result = await offload { Remover.remove(path) }
            let removedSomething = result.freed > 0 || result.skipped == 0
            report.outcomes.append(CleanOutcome(
                targetID: "trash:\(path)", title: "Trash › \(entry.name)", path: path, bytes: result.freed,
                succeeded: removedSomething,
                message: result.skipped > 0 ? "Left \(result.skipped) read-only or protected \(result.skipped == 1 ? "item" : "items") in place" : nil,
                rebuildHint: nil, trashedPaths: [], freedBytes: result.freed, trashedBytes: 0, skippedItems: result.skipped
            ))
        }
        report.diskFreedBytes = max(0, (SystemInfo.disk()?.available ?? 0) - before)
        History.append(report)
        return report
    }

    /// Cleans folder targets before commands so nested selections are skipped cleanly.
    /// Runs targets in a safe order: worktrees before folders inside them, app data before its app,
    /// and Docker containers last so their volumes and images aren't freed by an earlier prune.
    static func ordered(_ targets: [CleanTarget]) -> [CleanTarget] {
        func rank(_ target: CleanTarget) -> Int {
            switch target {
            case .artifact(let artifact, _) where artifact.kind == .worktree: return 0
            case .appData: return 1
            case .cache(let item) where item.group == .docker:
                return item.id == "docker-containers" ? 9 : 8
            default: return 5
            }
        }
        return targets.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func clean(_ target: CleanTarget, mode: DeleteMode, batchFiles: Set<String> = []) -> CleanOutcome {
        func failed(_ message: String) -> CleanOutcome {
            CleanOutcome(targetID: target.id, title: target.title, path: target.path, bytes: 0, succeeded: false,
                         message: message, rebuildHint: target.rebuildHint, trashedPaths: [], freedBytes: 0, trashedBytes: 0, skippedItems: nil)
        }
        func done(_ removal: Removal, note: String? = nil) -> CleanOutcome {
            var outcome = done(freed: removal.freed, trashed: removal.trashed, paths: removal.trashedPaths, skipped: removal.skipped, note: note)
            outcome.trashedIdentities = removal.trashedIdentities
            return outcome
        }
        func done(freed: Int64, trashed: Int64 = 0, paths: [String] = [], skipped: Int = 0, note: String? = nil) -> CleanOutcome {
            let removedSomething = freed > 0 || trashed > 0 || !paths.isEmpty || skipped == 0
            var message = note
            if skipped > 0 {
                message = "Left \(skipped) read-only or protected \(skipped == 1 ? "item" : "items") in place"
            }
            return CleanOutcome(targetID: target.id, title: target.title, path: target.path, bytes: freed + trashed,
                                succeeded: removedSomething, message: removedSomething ? message : (message ?? "Nothing could be removed"),
                                rebuildHint: target.rebuildHint, trashedPaths: paths, freedBytes: freed, trashedBytes: trashed, skippedItems: skipped)
        }

        if let reason = target.blockedReason { return failed(reason) }

        switch target {
        case .artifact(let artifact, let project):
            if let problem = recheck(artifact, in: project) { return failed(problem) }
            if artifact.kind == .worktree {
                return removeWorktree(artifact, project: project, failed: failed, done: { done($0, note: $1) })
            }
            let removal = remove([artifact.path], mode: mode)
            return done(removal)

        case .cache(let stored):
            guard let item = trustedCache(stored) else { return failed("Unknown cache, skipped for safety") }
            if let app = item.quitApp, ProcessInspector.processNames().contains(app) { return failed("Quit \(app) first") }
            let effectiveMode: DeleteMode = item.id == CacheCatalog.trashID ? .permanent : mode

            switch item.effectiveMethod {
            case .command(let tool, let arguments):
                guard let path = item.toolPath else { return failed("\(tool) isn't installed") }
                let before = item.paths.isEmpty ? 0 : DirectorySizer.size(of: item.paths).reclaimable
                let freeBefore = SystemInfo.plainAvailable()
                let result = Shell.run(path, arguments, timeout: 900)
                guard result.succeeded else {
                    return failed(firstLine(result.error) ?? firstLine(result.output) ?? "\(tool) failed")
                }
                if item.group == .docker {
                    return done(freed: DockerInspector.reclaimed(in: result.output) ?? 0)
                }
                if item.paths.isEmpty {
                    return done(freed: max(0, SystemInfo.plainAvailable() - freeBefore))
                }
                let after = DirectorySizer.size(of: item.paths).reclaimable
                return done(freed: max(0, before - after))
            case .deleteContents:
                var children: [String] = []
                for path in item.paths {
                    if let problem = unsafeCacheFolder(path) { return failed(problem) }
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                    children += names.map { path + "/" + $0 }
                }
                guard !children.isEmpty else { return failed("Already empty") }
                let removal = remove(children, mode: effectiveMode)
                return done(removal)
            case .deletePaths:
                for path in item.paths {
                    if let problem = unsafeCacheFolder(path) { return failed(problem) }
                }
                guard !item.paths.isEmpty else { return failed("Already gone") }
                let removal = remove(item.paths, mode: effectiveMode)
                return done(removal)
            case .evictDownloads:
                guard !item.paths.isEmpty else { return failed("Nothing left to remove") }
                var freed: Int64 = 0
                var skipped = 0
                for path in item.paths {
                    if ICloudDownloads.recheck(path) != nil {
                        skipped += 1
                        continue
                    }
                    let before = DirectorySizer.size(of: path).allocated
                    do {
                        try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
                        freed += before
                    } catch {
                        skipped += 1
                    }
                }
                return done(freed: freed, skipped: skipped)
            case nil:
                return failed("Tool not installed")
            }

        case .simulator(let stored):
            guard isUUID(stored.udid), let device = SimulatorInspector.devices().first(where: { $0.udid == stored.udid }) else {
                return failed("This simulator no longer exists")
            }
            if device.isBooted { return failed("Running. Shut it down first.") }
            let before = FileManager.default.fileExists(atPath: device.path) ? DirectorySizer.size(of: device.path).reclaimable : device.size.reclaimable
            let result = Shell.xcrun(["simctl", "delete", device.udid], timeout: 120)
            return result.succeeded ? done(freed: before) : failed(firstLine(result.error) ?? "simctl failed")

        case .runtime(let stored):
            guard isUUID(stored.id), let runtime = SimulatorInspector.runtimes().first(where: { $0.id == stored.id }) else {
                return failed("This runtime no longer exists")
            }
            guard runtime.isDeletable else { return failed("macOS manages this runtime") }
            let result = Shell.xcrun(["simctl", "runtime", "delete", runtime.id], timeout: 300)
            return result.succeeded ? done(freed: runtime.sizeBytes) : failed(firstLine(result.error) ?? "simctl failed")

        case .app(let stored):
            if let problem = AppInventory.recheck(stored) { return failed(problem) }
            guard let bundle = AppInventory.bundle(at: stored.path) else { return failed("The app changed since the scan") }
            let app = InstalledApp(bundleID: bundle.bundleID, name: bundle.name, path: bundle.path, version: bundle.version,
                                   isAppStore: stored.isAppStore, size: .zero, lastUsed: nil, leftovers: [])
            let leftovers = AppInventory.currentLeftovers(for: app).filter { !$0.mayHoldUserData }.map(\.path)
            if let problem = leftovers.lazy.compactMap({ unsafeLibraryItem($0) }).first { return failed(problem) }
            let moved = remove([app.path], mode: .trash, allowPartial: false)
            guard !moved.trashedPaths.isEmpty else {
                return failed("macOS needs your password to remove this app. Drag it to the Trash in Finder.")
            }
            var combined = remove(leftovers, mode: .trash)
            combined.trashed += moved.trashed
            combined.trashedPaths = moved.trashedPaths + combined.trashedPaths
            combined.trashedIdentities = moved.trashedIdentities + combined.trashedIdentities
            return done(combined)

        case .appData(let stored):
            if let problem = AppInventory.recheck(stored) { return failed(problem) }
            guard let bundle = AppInventory.bundle(at: stored.path) else { return failed("The app changed since the scan") }
            // Name and ID come from the app on disk now, never from the saved scan.
            let app = InstalledApp(bundleID: bundle.bundleID, name: bundle.name, path: bundle.path, version: bundle.version,
                                   isAppStore: stored.isAppStore, size: .zero, lastUsed: nil, leftovers: [])
            let paths = AppInventory.currentLeftovers(for: app).filter(\.mayHoldUserData).map(\.path)
            guard !paths.isEmpty else { return failed("Already gone") }
            if let problem = paths.lazy.compactMap({ unsafeLibraryItem($0) }).first { return failed(problem) }
            let removal = remove(paths, mode: .trash)
            return done(removal)

        case .orphan(let orphan):
            let paths = AppInventory.currentOrphanPaths(for: orphan)
            guard !paths.isEmpty else { return failed("The app is installed again, or the data is gone") }
            if let problem = paths.lazy.compactMap({ unsafeLibraryItem($0) }).first { return failed(problem) }
            let removal = remove(paths, mode: .trash)
            return done(removal)

        case .file(let file):
            if let problem = UserFiles.recheck(file) { return failed(problem) }
            if let problem = duplicateProblem(file, batchFiles: batchFiles) { return failed(problem) }
            let removal = remove([file.path], mode: .trash)
            return done(removal)
        }
    }

    /// Never removes every copy of a duplicate: one copy outside the batch (or the first one) is always kept and re-verified.
    static func duplicateProblem(_ file: UserFile, batchFiles: Set<String>) -> String? {
        guard let hash = file.contentHash, let others = file.otherCopies, !others.isEmpty else { return nil }
        let group = ([file.path] + others).sorted()
        let survivors = group.filter { !batchFiles.contains($0) }
        let keepers = survivors.isEmpty ? [group[0]] : survivors
        if keepers.contains(file.path) { return "Kept as the last copy" }
        guard UserFiles.fullHash(file.path) == hash else { return "Changed since the scan, so it's no longer a duplicate" }
        let verified = keepers.contains { path in
            !UserFiles.isDataless(path) && UserFiles.fullHash(path) == hash
        }
        return verified ? nil : "No identical copy is left, so this one is kept"
    }

    /// Confirms an artifact is still what the scan found and is safe to remove now.
    static func recheck(_ artifact: Artifact, in project: Project) -> String? {
        if let problem = unsafeLocation(project.path) ?? unsafeLocation(artifact.path) { return problem }
        guard artifact.path.isInside(project.path) else { return "Outside its project" }

        var st = stat()
        guard lstat(artifact.path, &st) == 0 else { return "Already gone" }
        guard st.st_mode & S_IFMT == S_IFDIR else { return "No longer a folder" }

        if artifact.kind == .worktree {
            guard artifact.path == project.path else { return "Worktree path doesn't match its project" }
            var gitStat = stat()
            guard lstat(project.path + "/.git", &gitStat) == 0, gitStat.st_mode & S_IFMT == S_IFREG else {
                return "Not a linked worktree"
            }
            guard ProjectFinder.gitFileKind(project.path) == .worktree else { return "Not a linked worktree" }
        } else {
            guard artifact.path != project.path else { return "Refusing to delete a project folder" }
            guard let rule = Rules.artifacts.first(where: { $0.id == artifact.ruleID }), rule.directory == artifact.folderName else {
                return "Folder name no longer matches its rule"
            }
            let parent = (artifact.path as NSString).deletingLastPathComponent
            let siblings = Set((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [])
            guard rule.matches(siblings: siblings) else { return "Its project file is gone, so it's left alone" }
            if rule.requiresGitIgnored {
                let root = gitRoot(containing: parent, within: project.path) ?? project.path
                guard GitInspector.ignoredPaths([artifact.path], root: root).contains(artifact.path) else {
                    return "Git no longer ignores this folder"
                }
            }
        }

        if let user = ProcessInspector.user(of: project.path, among: ProcessInspector.runningProcesses()) {
            return "In use by \(user.name)"
        }
        return nil
    }

    /// Paths that must never be deleted, whatever a scan says.
    static func unsafeLocation(_ path: String) -> String? {
        if path != path.resolvedPath, let problem = unsafeLocation(path.resolvedPath, resolved: true) { return problem }
        return unsafeLocation(path, resolved: true)
    }

    private static func unsafeLocation(_ path: String, resolved: Bool) -> String? {
        let standardized = (path as NSString).standardizingPath
        let home = NSHomeDirectory()
        let forbidden: Set<String> = [
            "/", "/Users", "/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin", "/opt", "/Volumes",
            home, "\(home)/Library", "\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads",
            "\(home)/Library/Mobile Documents", "\(home)/Library/CloudStorage",
        ]
        if forbidden.contains(where: { $0.lowercased() == standardized.lowercased() }) { return "Protected location" }
        if standardized.isInside("\(home)/Library/Mobile Documents") || standardized.isInside("\(home)/Library/CloudStorage") {
            return "Cloud-synced folder"
        }
        if standardized.isInside("/System") { return "Protected location" }
        if standardized.split(separator: "/").count < 3 { return "Protected location" }
        if standardized.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) { return "Inside a .git folder" }
        return nil
    }

    /// Checks a cache folder right before emptying it: it must be a real folder inside your home folder.
    static func unsafeCacheFolder(_ path: String, home: String = NSHomeDirectory()) -> String? {
        if SystemData.isMacOSInstaller(path) {
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return "Not a folder" }
            return nil
        }
        if let problem = unsafeLocation(path) { return problem }
        guard path.isInside(home), path != home else { return "Outside your home folder" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "Already gone" }
        if st.st_mode & S_IFMT == S_IFLNK { return "It's a link to another folder, so it's left alone" }
        guard st.st_mode & S_IFMT == S_IFDIR else { return "Not a folder" }
        return nil
    }

    static func isUUID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    /// App leftovers must sit directly in a known ~/Library folder and must not be links.
    static func unsafeLibraryItem(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let library = "\(home)/Library/"
        guard path.hasPrefix(library), !path.split(separator: "/").contains("..") else { return "Outside your Library folder" }
        let parent = String((path as NSString).deletingLastPathComponent.dropFirst(library.count))
        guard AppInventory.leftoverLocations.contains(where: { $0.folder == parent }) else { return "Not in an app data folder" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "Already gone" }
        if st.st_mode & S_IFMT == S_IFLNK { return "It's a link, so it's left alone" }
        return nil
    }

    /// Rebuilds a cache item from the built-in catalog so stored scan data never decides what gets deleted or run.
    static func trustedCache(_ stored: CacheItem) -> CacheItem? {
        if stored.group == .docker {
            guard let arguments = DockerInspector.commands[stored.id], let docker = ToolLocator.find("docker") else { return nil }
            return CacheItem(id: stored.id, name: stored.name, group: .docker, symbol: stored.symbol, detail: stored.detail,
                             paths: [], tier: stored.tier, method: .command(tool: "docker", arguments: arguments),
                             size: stored.size, toolPath: docker)
        }
        return CacheCatalog.trustedItem(id: stored.id)
    }

    private static func gitRoot(containing directory: String, within project: String) -> String? {
        var current = directory
        while current.isInside(project) {
            if FileManager.default.fileExists(atPath: current + "/.git") { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private static func removeWorktree(_ artifact: Artifact, project: Project,
                                       failed: (String) -> CleanOutcome,
                                       done: (Removal, String?) -> CleanOutcome) -> CleanOutcome {
        let git = GitInspector.inspect(project.path, isWorktree: true)
        if let blocker = Scanner.worktreeBlocker(git, user: nil) { return failed(blocker) }
        guard let main = git.mainRepositoryPath else { return failed("Couldn't find the main repository") }
        // The Trash keeps git-ignored files like .env recoverable; git worktree remove would delete them for good.
        let removal = remove([artifact.path], mode: .trash, allowPartial: false)
        guard !removal.trashedPaths.isEmpty else { return failed("Couldn't move the worktree to the Trash") }
        let prune = Shell.git(["worktree", "prune"], in: main)
        return done(removal, prune.succeeded ? nil : "Moved to the Trash. Run git worktree prune in the main repository.")
    }

    struct Removal {
        var freed: Int64 = 0
        var trashed: Int64 = 0
        var skipped = 0
        var trashedPaths: [String] = []
        var trashedIdentities: [String] = []
    }

    static func identity(of path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }

    /// Removes each path, measuring what actually went and skipping anything that can't be removed.
    /// `allowPartial: false` keeps a path whole: it goes to the Trash in one piece or not at all (app bundles).
    static func remove(_ paths: [String], mode: DeleteMode, allowPartial: Bool = true) -> Removal {
        var removal = Removal()
        for path in paths {
            if mode == .trash {
                trash(path, into: &removal, depth: allowPartial ? 0 : Int.max)
            } else {
                let result = Remover.remove(path)
                removal.freed += result.freed
                removal.skipped += result.skipped
            }
        }
        return removal
    }

    /// Moves a path to the Trash; if macOS refuses (read-only folders), tries its children so the rest still goes.
    private static func trash(_ path: String, into removal: inout Removal, depth: Int) {
        let size = DirectorySizer.size(of: path).reclaimable
        if let moved = TrashBin.move(path) {
            removal.trashed += size
            removal.trashedPaths.append(moved)
            removal.trashedIdentities.append(identity(of: moved) ?? "")
            return
        }

        var st = stat()
        guard depth < 4, depth >= 0, lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              let children = try? FileManager.default.contentsOfDirectory(atPath: path), !children.isEmpty
        else {
            removal.skipped += 1
            return
        }
        for child in children {
            trash(path + "/" + child, into: &removal, depth: depth + 1)
        }
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

public enum History {
    /// Test hook: redirects history and scan cache away from Application Support.
    nonisolated(unsafe) static var overrideDirectory: URL?

    public static var directory: URL {
        if let overrideDirectory { return overrideDirectory }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DevSweep", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("history.jsonl") }

    static func append(_ report: CleanReport) {
        guard !report.outcomes.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(report) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
        trim()
    }

    static let maxRuns = 200

    /// Keeps only the most recent runs so the history file can't grow forever.
    static func trim() {
        guard let data = try? Data(contentsOf: file) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > maxRuns else { return }
        var kept = Data()
        for line in lines.suffix(maxRuns) {
            kept.append(line)
            kept.append(0x0A)
        }
        try? kept.write(to: file, options: .atomic)
    }

    public static func load() -> [CleanReport] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(CleanReport.self, from: Data($0)) }.reversed()
    }
}

public enum ScanCache {
    static var file: URL { History.directory.appendingPathComponent("last-scan.json") }

    public static func save(_ result: ScanResult) {
        try? FileManager.default.createDirectory(at: History.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(result) { try? data.write(to: file, options: .atomic) }
    }

    public static func load() -> ScanResult? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanResult.self, from: data)
    }
}

/// Moves items to the Trash; tests point it at a temporary folder so they never touch the real Trash.
public enum TrashBin {
    nonisolated(unsafe) static var overrideDirectory: URL?

    /// Moves `path` to the Trash and returns where it went, or nil if macOS refused.
    static func move(_ path: String) -> String? {
        if let overrideDirectory {
            let target = overrideDirectory.appendingPathComponent(UUID().uuidString + "-" + (path as NSString).lastPathComponent)
            return (try? FileManager.default.moveItem(atPath: path, toPath: target.path)) != nil ? target.path : nil
        }
        var resulting: NSURL?
        guard (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)) != nil else { return nil }
        return resulting?.path
    }
}
