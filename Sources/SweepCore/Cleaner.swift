import Darwin
import Foundation

public enum CleanTarget: Identifiable, Hashable, Sendable {
    case artifact(Artifact, project: Project)
    case cache(CacheItem)
    case simulator(SimulatorDevice)
    case runtime(SimulatorRuntime)

    public var id: String {
        switch self {
        case .artifact(let artifact, _): "artifact:\(artifact.path)"
        case .cache(let item): "cache:\(item.id)"
        case .simulator(let device): "simulator:\(device.udid)"
        case .runtime(let runtime): "runtime:\(runtime.id)"
        }
    }

    public var title: String {
        switch self {
        case .artifact(let artifact, let project):
            artifact.kind == .worktree ? "\(project.name) worktree" : "\(project.name) › \(artifact.folderName)"
        case .cache(let item): item.name
        case .simulator(let device): "\(device.name) (\(device.runtime))"
        case .runtime(let runtime): "\(runtime.name) runtime"
        }
    }

    public var bytes: Int64 {
        switch self {
        case .artifact(let artifact, _): artifact.size.reclaimable
        case .cache(let item): item.size.reclaimable
        case .simulator(let device): device.size.reclaimable
        case .runtime(let runtime): runtime.sizeBytes
        }
    }

    public var tier: SafetyTier {
        switch self {
        case .artifact(let artifact, _): artifact.tier
        case .cache(let item): item.tier
        case .simulator, .runtime: .rebuildable
        }
    }

    public var path: String? {
        switch self {
        case .artifact(let artifact, _): artifact.path
        case .cache(let item): item.paths.first
        case .simulator(let device): device.path
        case .runtime: nil
        }
    }

    public var rebuildHint: String? {
        switch self {
        case .artifact(let artifact, _): artifact.rebuildHint
        case .cache: nil
        case .simulator: "Create it again in Xcode › Devices and Simulators"
        case .runtime: "Download it again in Xcode › Settings › Components"
        }
    }

    public var blockedReason: String? {
        switch self {
        case .artifact(let artifact, _): artifact.blockedReason
        case .cache(let item): item.blockedReason
        case .simulator(let device): device.isBooted ? "Running. Shut it down first." : nil
        case .runtime(let runtime): runtime.isDeletable ? nil : "macOS manages this runtime"
        }
    }

    /// Whether deletion goes through the Trash (commands always delete directly).
    func usesTrash(_ mode: DeleteMode) -> Bool {
        guard mode == .trash else { return false }
        switch self {
        case .artifact(let artifact, _): return artifact.kind == .folder
        case .cache(let item):
            if case .command = item.effectiveMethod { return false }
            return true
        case .simulator, .runtime: return false
        }
    }
}

public struct CleanOutcome: Codable, Hashable, Sendable, Identifiable {
    public var id: String { targetID }
    public let targetID: String
    public let title: String
    public let path: String?
    public let bytes: Int64
    public let succeeded: Bool
    public let message: String?
    public let rebuildHint: String?
    public let trashedPaths: [String]
}

public struct CleanReport: Codable, Hashable, Sendable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let mode: DeleteMode
    public var outcomes: [CleanOutcome]
    public var diskFreedBytes: Int64

    public var cleanedBytes: Int64 { outcomes.filter(\.succeeded).reduce(0) { $0 + $1.bytes } }
    public var trashedBytes: Int64 { outcomes.filter { $0.succeeded && !$0.trashedPaths.isEmpty }.reduce(0) { $0 + $1.bytes } }
    public var failures: [CleanOutcome] { outcomes.filter { !$0.succeeded } }
    public var trashedPaths: [String] { outcomes.flatMap(\.trashedPaths) }
}

public enum Cleaner {
    public static func clean(_ targets: [CleanTarget], mode: DeleteMode, progress: (@Sendable (Int, CleanTarget) -> Void)? = nil) async -> CleanReport {
        let before = SystemInfo.disk()?.available ?? 0
        var report = CleanReport(date: Date(), mode: mode, outcomes: [], diskFreedBytes: 0)

        for (index, target) in ordered(targets).enumerated() {
            progress?(index, target)
            let outcome = await Task.detached { clean(target, mode: mode) }.value
            report.outcomes.append(outcome)
        }

        let after = SystemInfo.disk()?.available ?? 0
        report.diskFreedBytes = max(0, after - before)
        History.append(report)
        return report
    }

    /// Permanently removes items this app moved to the Trash.
    public static func emptyFromTrash(_ paths: [String]) -> Int {
        var removed = 0
        let trash = SystemInfo.trashPath
        for path in paths where path.isInside(trash) {
            if (try? FileManager.default.removeItem(atPath: path)) != nil { removed += 1 }
        }
        return removed
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

    private static func clean(_ target: CleanTarget, mode: DeleteMode) -> CleanOutcome {
        func outcome(_ succeeded: Bool, _ message: String? = nil, trashed: [String] = []) -> CleanOutcome {
            CleanOutcome(targetID: target.id, title: target.title, path: target.path, bytes: succeeded ? target.bytes : 0,
                         succeeded: succeeded, message: message, rebuildHint: target.rebuildHint, trashedPaths: trashed)
        }

        if let reason = target.blockedReason { return outcome(false, reason) }

        switch target {
        case .artifact(let artifact, let project):
            if let problem = recheck(artifact, in: project) { return outcome(false, problem) }
            if artifact.kind == .worktree {
                return removeWorktree(artifact, project: project, outcome: outcome)
            }
            return delete([artifact.path], mode: mode, outcome: outcome)

        case .cache(let item):
            switch item.effectiveMethod {
            case .command(_, let arguments):
                guard let tool = item.toolPath else { return outcome(false, "Tool not found") }
                let result = Shell.run(tool, arguments, timeout: 900)
                if result.succeeded { return outcome(true) }
                return outcome(false, firstLine(result.error) ?? "The command failed")
            case .deleteContents:
                let children = item.paths.flatMap { path in
                    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).map { path + "/" + $0 }
                }
                return delete(children, mode: mode, outcome: outcome)
            case .deletePaths:
                return delete(item.paths, mode: mode, outcome: outcome)
            case nil:
                return outcome(false, "Tool not installed")
            }

        case .simulator(let device):
            let result = Shell.run("/usr/bin/xcrun", ["simctl", "delete", device.udid], timeout: 120)
            return result.succeeded ? outcome(true) : outcome(false, firstLine(result.error) ?? "simctl failed")

        case .runtime(let runtime):
            let result = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", runtime.id], timeout: 300)
            return result.succeeded ? outcome(true) : outcome(false, firstLine(result.error) ?? "simctl failed")
        }
    }

    /// Confirms an artifact is still what the scan found and is safe to remove now.
    static func recheck(_ artifact: Artifact, in project: Project) -> String? {
        var st = stat()
        guard lstat(artifact.path, &st) == 0 else { return "Already gone" }
        guard st.st_mode & S_IFMT == S_IFDIR else { return "No longer a folder" }
        guard artifact.path.isInside(project.path) else { return "Outside its project" }
        if artifact.kind == .folder {
            guard artifact.path != project.path else { return "Refusing to delete a project folder" }
            guard Rules.artifacts.contains(where: { $0.id == artifact.ruleID && $0.directory == artifact.folderName }) else {
                return "Folder name no longer matches its rule"
            }
        }
        if let user = ProcessInspector.user(of: artifact.path, among: ProcessInspector.runningProcesses()) {
            return "In use by \(user.name)"
        }
        return nil
    }

    private static func removeWorktree(_ artifact: Artifact, project: Project, outcome: (Bool, String?, [String]) -> CleanOutcome) -> CleanOutcome {
        let git = GitInspector.inspect(project.path, isWorktree: true)
        if let blocker = Scanner.worktreeBlocker(git, user: nil) { return outcome(false, blocker, []) }
        guard let main = git.mainRepositoryPath else { return outcome(false, "Couldn't find the main repository", []) }
        let result = Shell.git(["worktree", "remove", artifact.path], in: main, timeout: 300)
        if result.succeeded { return outcome(true, nil, []) }
        return outcome(false, firstLine(result.error) ?? "git worktree remove failed", [])
    }

    private static func delete(_ paths: [String], mode: DeleteMode, outcome: (Bool, String?, [String]) -> CleanOutcome) -> CleanOutcome {
        let fileManager = FileManager.default
        var trashed: [String] = []
        var failures: [String] = []

        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                if mode == .trash {
                    var resulting: NSURL?
                    try fileManager.trashItem(at: url, resultingItemURL: &resulting)
                    if let resultPath = resulting?.path { trashed.append(resultPath) }
                } else {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                failures.append((path as NSString).lastPathComponent)
            }
        }

        if failures.isEmpty { return outcome(true, nil, trashed) }
        let message = "Couldn't remove \(failures.prefix(3).joined(separator: ", "))\(failures.count > 3 ? " and \(failures.count - 3) more" : "")"
        return outcome(failures.count < paths.count, message, trashed)
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
