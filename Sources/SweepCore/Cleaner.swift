import Darwin
import Foundation

public enum CleanTarget: Identifiable, Hashable, Sendable {
    case artifact(Artifact, project: Project)
    case cache(CacheItem)
    case simulator(SimulatorDevice)
    case runtime(SimulatorRuntime)
    case file(UserFile)

    public var id: String {
        switch self {
        case .artifact(let artifact, _): "artifact:\(artifact.path)"
        case .cache(let item): "cache:\(item.id)"
        case .simulator(let device): "simulator:\(device.udid)"
        case .runtime(let runtime): "runtime:\(runtime.id)"
        case .file(let file): "file:\(file.path)"
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
        }
    }

    public var bytes: Int64 {
        switch self {
        case .artifact(let artifact, _): artifact.size.reclaimable
        case .cache(let item): item.size.reclaimable
        case .simulator(let device): device.size.reclaimable
        case .runtime(let runtime): runtime.sizeBytes
        case .file(let file): file.reclaimable
        }
    }

    public var tier: SafetyTier {
        switch self {
        case .artifact(let artifact, _): artifact.tier
        case .cache(let item): item.tier
        case .simulator, .runtime: .rebuildable
        case .file: .review
        }
    }

    public var path: String? {
        switch self {
        case .artifact(let artifact, _): artifact.path
        case .cache(let item): item.paths.first
        case .simulator(let device): device.path
        case .runtime: nil
        case .file(let file): file.path
        }
    }

    public var rebuildHint: String? {
        switch self {
        case .artifact(let artifact, _): artifact.rebuildHint
        case .cache: nil
        case .simulator: "Create it again in Xcode › Devices and Simulators"
        case .runtime: "Download it again in Xcode › Settings › Components"
        case .file: "Put it back from the Trash if you need it"
        }
    }

    public var blockedReason: String? {
        switch self {
        case .artifact(let artifact, _): artifact.blockedReason
        case .cache(let item): item.blockedReason
        case .simulator(let device): device.isBooted ? "Running. Shut it down first." : nil
        case .runtime(let runtime): runtime.isDeletable ? nil : "macOS manages this runtime"
        case .file: nil
        }
    }

    /// Whether deletion goes through the Trash (commands always delete directly).
    public func usesTrash(_ mode: DeleteMode) -> Bool {
        if case .file = self { return true }
        guard mode == .trash else { return false }
        switch self {
        case .artifact(let artifact, _): return artifact.kind == .folder
        case .cache(let item):
            if item.id == CacheCatalog.trashID { return false }
            if case .command = item.effectiveMethod { return false }
            return true
        case .simulator, .runtime: return false
        case .file: return true
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
        for (index, target) in ordered(targets).enumerated() {
            progress?(index, target)
            let outcome = await offload { clean(target, mode: mode, batchFiles: batchFiles) }
            report.outcomes.append(outcome)
        }

        let after = SystemInfo.disk()?.available ?? 0
        report.diskFreedBytes = max(0, after - before)
        History.append(report)
        return report
    }

    /// Permanently removes items this app moved to the Trash, skipping anything that can't be deleted.
    public static func emptyFromTrash(_ paths: [String]) -> (removed: Int, freed: Int64, skipped: Int) {
        var removed = 0
        var freed: Int64 = 0
        var skipped = 0
        let trash = SystemInfo.trashPath
        for path in paths.map({ ($0 as NSString).standardizingPath }) where path.isInside(trash) && path != trash {
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
    private static func ordered(_ targets: [CleanTarget]) -> [CleanTarget] {
        let worktrees = targets.compactMap { target -> String? in
            if case .artifact(let artifact, _) = target, artifact.kind == .worktree { return artifact.path }
            return nil
        }
        return targets.filter { target in
            guard case .artifact(let artifact, _) = target, artifact.kind == .folder else { return true }
            return !worktrees.contains { artifact.path.isInside($0) }
        }
    }

    private static func clean(_ target: CleanTarget, mode: DeleteMode, batchFiles: Set<String> = []) -> CleanOutcome {
        func failed(_ message: String) -> CleanOutcome {
            CleanOutcome(targetID: target.id, title: target.title, path: target.path, bytes: 0, succeeded: false,
                         message: message, rebuildHint: target.rebuildHint, trashedPaths: [], freedBytes: 0, trashedBytes: 0, skippedItems: nil)
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
                return removeWorktree(artifact, project: project, failed: failed, done: done)
            }
            let removal = remove([artifact.path], mode: mode)
            return done(freed: removal.freed, trashed: removal.trashed, paths: removal.trashedPaths, skipped: removal.skipped)

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
                return done(freed: removal.freed, trashed: removal.trashed, paths: removal.trashedPaths, skipped: removal.skipped)
            case .deletePaths:
                for path in item.paths {
                    if let problem = unsafeCacheFolder(path) { return failed(problem) }
                }
                guard !item.paths.isEmpty else { return failed("Already gone") }
                let removal = remove(item.paths, mode: effectiveMode)
                return done(freed: removal.freed, trashed: removal.trashed, paths: removal.trashedPaths, skipped: removal.skipped)
            case nil:
                return failed("Tool not installed")
            }

        case .simulator(let device):
            let before = FileManager.default.fileExists(atPath: device.path) ? DirectorySizer.size(of: device.path).reclaimable : device.size.reclaimable
            let result = Shell.run("/usr/bin/xcrun", ["simctl", "delete", device.udid], timeout: 120)
            return result.succeeded ? done(freed: before) : failed(firstLine(result.error) ?? "simctl failed")

        case .runtime(let runtime):
            let result = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", runtime.id], timeout: 300)
            return result.succeeded ? done(freed: runtime.sizeBytes) : failed(firstLine(result.error) ?? "simctl failed")

        case .file(let file):
            if let problem = UserFiles.recheck(file) { return failed(problem) }
            if let problem = duplicateProblem(file, batchFiles: batchFiles) { return failed(problem) }
            let removal = remove([file.path], mode: .trash)
            return done(freed: removal.freed, trashed: removal.trashed, paths: removal.trashedPaths, skipped: removal.skipped)
        }
    }

    /// Never removes every copy of a duplicate: one copy outside the batch (or the first one) is always kept and re-verified.
    static func duplicateProblem(_ file: UserFile, batchFiles: Set<String>) -> String? {
        guard let hash = file.contentHash, let others = file.otherCopies, !others.isEmpty else { return nil }
        let group = ([file.path] + others).sorted()
        let survivors = group.filter { !batchFiles.contains($0) }
        let keepers = survivors.isEmpty ? [group[0]] : survivors
        if keepers.contains(file.path) { return "Kept as the last copy" }
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

        if let user = ProcessInspector.user(of: artifact.path, among: ProcessInspector.runningProcesses()) {
            return "In use by \(user.name)"
        }
        return nil
    }

    /// Paths that must never be deleted, whatever a scan says.
    static func unsafeLocation(_ path: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        let home = NSHomeDirectory()
        let forbidden: Set<String> = [
            "/", "/Users", "/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin", "/opt", "/Volumes",
            home, "\(home)/Library", "\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads",
            "\(home)/Library/Mobile Documents", "\(home)/Library/CloudStorage",
        ]
        if forbidden.contains(standardized) { return "Protected location" }
        if standardized.isInside("\(home)/Library/Mobile Documents") || standardized.isInside("\(home)/Library/CloudStorage") {
            return "Cloud-synced folder"
        }
        if standardized.isInside("/System") { return "Protected location" }
        if standardized.split(separator: "/").count < 3 { return "Protected location" }
        if standardized.split(separator: "/").contains(".git") { return "Inside a .git folder" }
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
                                       done: (Int64, Int64, [String], Int, String?) -> CleanOutcome) -> CleanOutcome {
        let git = GitInspector.inspect(project.path, isWorktree: true)
        if let blocker = Scanner.worktreeBlocker(git, user: nil) { return failed(blocker) }
        guard let main = git.mainRepositoryPath else { return failed("Couldn't find the main repository") }
        let before = DirectorySizer.size(of: artifact.path).reclaimable
        let result = Shell.git(["worktree", "remove", artifact.path], in: main, timeout: 300)
        guard result.succeeded else { return failed(firstLine(result.error) ?? "git worktree remove failed") }
        return done(before, 0, [], 0, nil)
    }

    struct Removal {
        var freed: Int64 = 0
        var trashed: Int64 = 0
        var skipped = 0
        var trashedPaths: [String] = []
    }

    /// Removes each path, measuring what actually went and skipping anything that can't be removed.
    static func remove(_ paths: [String], mode: DeleteMode) -> Removal {
        var removal = Removal()
        for path in paths {
            if mode == .trash {
                trash(path, into: &removal, depth: 0)
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
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
            removal.trashed += size
            if let moved = resulting?.path { removal.trashedPaths.append(moved) }
            return
        } catch {}

        var st = stat()
        guard depth < 4, lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
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
