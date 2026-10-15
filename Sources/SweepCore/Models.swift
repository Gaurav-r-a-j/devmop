import Foundation

public enum SafetyTier: String, Codable, CaseIterable, Comparable, Sendable {
    case safe
    case rebuildable
    case review
    case protected

    public var title: String {
        switch self {
        case .safe: "Safe"
        case .rebuildable: "Rebuildable"
        case .review: "Review"
        case .protected: "Protected"
        }
    }

    public var summary: String {
        switch self {
        case .safe: "Cache only. Tools recreate it automatically."
        case .rebuildable: "Recreated by reinstalling or rebuilding."
        case .review: "May hold data or work. Check before deleting."
        case .protected: "Never deleted."
        }
    }

    private var rank: Int {
        switch self {
        case .safe: 0
        case .rebuildable: 1
        case .review: 2
        case .protected: 3
        }
    }

    public static func < (lhs: SafetyTier, rhs: SafetyTier) -> Bool { lhs.rank < rhs.rank }
}

public struct SizeInfo: Codable, Hashable, Sendable {
    /// Bytes the item occupies on disk.
    public var allocated: Int64
    /// Bytes that deleting the item actually frees.
    public var reclaimable: Int64
    public var fileCount: Int
    /// True when the reclaimable figure is an upper bound.
    public var isEstimate: Bool
    public var unreadableCount: Int

    public init(allocated: Int64 = 0, reclaimable: Int64 = 0, fileCount: Int = 0, isEstimate: Bool = false, unreadableCount: Int = 0) {
        self.allocated = allocated
        self.reclaimable = reclaimable
        self.fileCount = fileCount
        self.isEstimate = isEstimate
        self.unreadableCount = unreadableCount
    }

    public static let zero = SizeInfo()

    public static func + (lhs: SizeInfo, rhs: SizeInfo) -> SizeInfo {
        SizeInfo(
            allocated: lhs.allocated + rhs.allocated,
            reclaimable: lhs.reclaimable + rhs.reclaimable,
            fileCount: lhs.fileCount + rhs.fileCount,
            isEstimate: lhs.isEstimate || rhs.isEstimate,
            unreadableCount: lhs.unreadableCount + rhs.unreadableCount
        )
    }
}

public enum Ecosystem: String, Codable, CaseIterable, Sendable {
    case node, python, rust, swift, apple, gradle, go, dart, ruby, php, java, elixir, dotnet, terraform

    public var title: String {
        switch self {
        case .node: "Node.js"
        case .python: "Python"
        case .rust: "Rust"
        case .swift: "Swift"
        case .apple: "Xcode"
        case .gradle: "Gradle"
        case .go: "Go"
        case .dart: "Flutter"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .java: "Java"
        case .elixir: "Elixir"
        case .dotnet: ".NET"
        case .terraform: "Terraform"
        }
    }
}

public enum ArtifactKind: String, Codable, Sendable {
    case folder
    case worktree
}

public struct Artifact: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let ruleID: String
    public let name: String
    public let tier: SafetyTier
    public let kind: ArtifactKind
    public let rebuildHint: String?
    public var size: SizeInfo
    public var blockedReason: String?
    public var warning: String?

    public init(path: String, ruleID: String, name: String, tier: SafetyTier, kind: ArtifactKind = .folder, rebuildHint: String?, size: SizeInfo = .zero, blockedReason: String? = nil, warning: String? = nil) {
        self.path = path
        self.ruleID = ruleID
        self.name = name
        self.tier = tier
        self.kind = kind
        self.rebuildHint = rebuildHint
        self.size = size
        self.blockedReason = blockedReason
        self.warning = warning
    }

    public var folderName: String { (path as NSString).lastPathComponent }
}

public struct GitState: Codable, Hashable, Sendable {
    public var branch: String?
    public var isWorktree: Bool
    public var isLocked: Bool
    public var changedFiles: Int
    /// Commits not on any remote; nil when the repository has no remote.
    public var unpushedCommits: Int?
    /// For worktrees: commits whose changes are not in the base branch.
    public var commitsNotInBase: Int?
    public var baseBranch: String?
    public var mainRepositoryPath: String?
    public var lastCommitDate: Date?

    public init(branch: String? = nil, isWorktree: Bool = false, isLocked: Bool = false, changedFiles: Int = 0, unpushedCommits: Int? = nil, commitsNotInBase: Int? = nil, baseBranch: String? = nil, mainRepositoryPath: String? = nil, lastCommitDate: Date? = nil) {
        self.branch = branch
        self.isWorktree = isWorktree
        self.isLocked = isLocked
        self.changedFiles = changedFiles
        self.unpushedCommits = unpushedCommits
        self.commitsNotInBase = commitsNotInBase
        self.baseBranch = baseBranch
        self.mainRepositoryPath = mainRepositoryPath
        self.lastCommitDate = lastCommitDate
    }

    public var hasLocalWork: Bool {
        changedFiles > 0 || (unpushedCommits ?? 0) > 0 || (commitsNotInBase ?? 0) > 0
    }
}

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public var name: String
    public var ecosystems: [Ecosystem]
    public var artifacts: [Artifact]
    public var lastModified: Date?
    public var git: GitState?
    public var runningProcess: String?
    public var hasLockfile: Bool

    public init(path: String, name: String, ecosystems: [Ecosystem] = [], artifacts: [Artifact] = [], lastModified: Date? = nil, git: GitState? = nil, runningProcess: String? = nil, hasLockfile: Bool = false) {
        self.path = path
        self.name = name
        self.ecosystems = ecosystems
        self.artifacts = artifacts
        self.lastModified = lastModified
        self.git = git
        self.runningProcess = runningProcess
        self.hasLockfile = hasLockfile
    }

    public var lastActive: Date? {
        [lastModified, git?.lastCommitDate].compactMap { $0 }.max()
    }

    public var isInUse: Bool { runningProcess != nil }

    /// Space freed by deleting every build folder (worktree removal excluded).
    public var reclaimable: Int64 {
        artifacts.filter { $0.kind == .folder }.reduce(0) { $0 + $1.size.reclaimable }
    }

    public var allocated: Int64 {
        artifacts.filter { $0.kind == .folder }.reduce(0) { $0 + $1.size.allocated }
    }

    public var worktreeArtifact: Artifact? { artifacts.first { $0.kind == .worktree } }

    public func inactiveDays(now: Date = Date()) -> Int? {
        guard let lastActive else { return nil }
        return Calendar.current.dateComponents([.day], from: lastActive, to: now).day
    }

    public func isInactive(days: Int, now: Date = Date()) -> Bool {
        guard let idle = inactiveDays(now: now) else { return true }
        return idle >= days
    }
}

public enum CleanMethod: Codable, Hashable, Sendable {
    /// Runs the tool's own clean command.
    case command(tool: String, arguments: [String])
    /// Deletes everything inside each path, keeping the folder.
    case deleteContents
    /// Deletes each path itself.
    case deletePaths
}

public enum CacheGroup: String, Codable, CaseIterable, Sendable {
    case packageManagers
    case apple
    case languages
    case editors
    case testing
    case docker

    public var title: String {
        switch self {
        case .packageManagers: "Package managers"
        case .apple: "Xcode"
        case .languages: "Languages & build tools"
        case .editors: "Editors"
        case .testing: "Browsers for testing"
        case .docker: "Docker"
        }
    }
}

public struct CacheItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let group: CacheGroup
    public let symbol: String
    public let detail: String
    public var paths: [String]
    public let tier: SafetyTier
    public let method: CleanMethod
    public let fallback: CleanMethod?
    public var size: SizeInfo
    public var toolPath: String?
    public var blockedReason: String?

    public init(id: String, name: String, group: CacheGroup, symbol: String, detail: String, paths: [String], tier: SafetyTier, method: CleanMethod, fallback: CleanMethod? = nil, size: SizeInfo = .zero, toolPath: String? = nil, blockedReason: String? = nil) {
        self.id = id
        self.name = name
        self.group = group
        self.symbol = symbol
        self.detail = detail
        self.paths = paths
        self.tier = tier
        self.method = method
        self.fallback = fallback
        self.size = size
        self.toolPath = toolPath
        self.blockedReason = blockedReason
    }

    /// The method that will run, given which tools are installed.
    public var effectiveMethod: CleanMethod? {
        if case .command = method {
            return toolPath != nil ? method : fallback
        }
        return method
    }

    public var methodDescription: String {
        switch effectiveMethod {
        case .command(let tool, let arguments):
            return "Runs \(([tool] + arguments).joined(separator: " "))"
        case .deleteContents:
            return "Empties the folder"
        case .deletePaths:
            return paths.count == 1 ? "Deletes the folder" : "Deletes \(paths.count) folders"
        case nil:
            return "Tool not installed"
        }
    }

    public var isCleanable: Bool { blockedReason == nil && effectiveMethod != nil && size.reclaimable > 0 }
}

public struct SimulatorDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: String { udid }
    public let udid: String
    public let name: String
    public let runtime: String
    public let state: String
    public let isAvailable: Bool
    public let path: String
    public var size: SizeInfo
    public var lastBooted: Date?

    public init(udid: String, name: String, runtime: String, state: String, isAvailable: Bool, path: String, size: SizeInfo = .zero, lastBooted: Date? = nil) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
        self.isAvailable = isAvailable
        self.path = path
        self.size = size
        self.lastBooted = lastBooted
    }

    public var isBooted: Bool { state == "Booted" }
}

public struct SimulatorRuntime: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let sizeBytes: Int64
    public let isDeletable: Bool
    public let lastUsed: Date?

    public init(id: String, name: String, sizeBytes: Int64, isDeletable: Bool, lastUsed: Date?) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.isDeletable = isDeletable
        self.lastUsed = lastUsed
    }
}

public struct DiskUsage: Codable, Hashable, Sendable {
    public var total: Int64
    public var available: Int64

    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
    }

    public var used: Int64 { total - available }
}

public struct ScanResult: Codable, Sendable {
    public var date: Date
    public var duration: TimeInterval
    public var roots: [String]
    public var projects: [Project]
    public var caches: [CacheItem]
    public var simulators: [SimulatorDevice]
    public var runtimes: [SimulatorRuntime]
    public var dockerRunning: Bool?
    public var disk: DiskUsage?
    public var trashSize: Int64
    public var hasLocalSnapshots: Bool
    public var hasFullDiskAccess: Bool

    public init(date: Date = Date(), duration: TimeInterval = 0, roots: [String] = [], projects: [Project] = [], caches: [CacheItem] = [], simulators: [SimulatorDevice] = [], runtimes: [SimulatorRuntime] = [], dockerRunning: Bool? = nil, disk: DiskUsage? = nil, trashSize: Int64 = 0, hasLocalSnapshots: Bool = false, hasFullDiskAccess: Bool = true) {
        self.date = date
        self.duration = duration
        self.roots = roots
        self.projects = projects
        self.caches = caches
        self.simulators = simulators
        self.runtimes = runtimes
        self.dockerRunning = dockerRunning
        self.disk = disk
        self.trashSize = trashSize
        self.hasLocalSnapshots = hasLocalSnapshots
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    public var projectBytes: Int64 { projects.reduce(0) { $0 + $1.reclaimable } }
    public var cacheBytes: Int64 { caches.filter { $0.group != .docker }.reduce(0) { $0 + $1.size.reclaimable } }
    public var dockerBytes: Int64 { caches.filter { $0.group == .docker }.reduce(0) { $0 + $1.size.reclaimable } }
    public var simulatorBytes: Int64 {
        simulators.reduce(0) { $0 + $1.size.reclaimable } + runtimes.filter(\.isDeletable).reduce(0) { $0 + $1.sizeBytes }
    }
    public var totalReclaimable: Int64 { projectBytes + cacheBytes + dockerBytes + simulatorBytes }
}

public struct ScanProgress: Sendable {
    public enum Phase: String, Sendable {
        case findingProjects, measuring, checkingGit, caches, simulators, docker, done
    }

    public let phase: Phase
    public let message: String
    public let fraction: Double?

    public init(phase: Phase, message: String, fraction: Double? = nil) {
        self.phase = phase
        self.message = message
        self.fraction = fraction
    }
}

public enum DeleteMode: String, Codable, CaseIterable, Sendable {
    case trash
    case permanent

    public var title: String {
        switch self {
        case .trash: "Move to Trash"
        case .permanent: "Delete permanently"
        }
    }
}

public struct SweepSettings: Codable, Hashable, Sendable {
    public var roots: [String]
    public var excludedPaths: [String]
    public var inactiveDays: Int
    public var deleteMode: DeleteMode
    public var includeExternalVolumes: Bool

    public init(roots: [String] = [NSHomeDirectory()], excludedPaths: [String] = [], inactiveDays: Int = 60, deleteMode: DeleteMode = .trash, includeExternalVolumes: Bool = false) {
        self.roots = roots
        self.excludedPaths = excludedPaths
        self.inactiveDays = inactiveDays
        self.deleteMode = deleteMode
        self.includeExternalVolumes = includeExternalVolumes
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }

    public var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }

    func isInside(_ ancestor: String) -> Bool {
        self == ancestor || hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }
}
