import Foundation

public struct Scanner: Sendable {
    public let settings: SweepSettings

    public init(settings: SweepSettings) {
        self.settings = settings
    }

    public func scan(previous: ScanResult? = nil, progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> ScanResult {
        let started = Date()
        let mark = ChangeJournal.currentMark()
        let reuse = await offload { SizeReuse(previous: previous, settings: settings) }
        let runningNames = ProcessInspector.processNames()

        async let projects = scanProjects(reuse: reuse, progress: progress)
        async let caches = CacheCatalog.scan(runningNames: runningNames, previous: previous?.caches, reuse: reuse)
        async let simulators = offload { SimulatorInspector.devices() }
        async let runtimes = offload { SimulatorInspector.runtimes() }
        async let docker = offload { DockerInspector.scan() }
        async let trash = offload {
            reuse?.cached(SystemInfo.trashPath, previous?.trashSize) ?? DirectorySizer.size(of: SystemInfo.trashPath).allocated
        }
        async let snapshots = offload { SystemInfo.hasLocalSnapshots() }
        async let files = offload { UserFiles.scan() }
        async let inventory = AppInventory.scan(reuse: reuse)
        async let storage = StorageMap.measure(reuse: reuse)

        let dockerResult = await docker
        let (projectList, measuredCount) = await projects
        var result = ScanResult(
            date: started,
            roots: settings.roots,
            projects: projectList,
            caches: await caches + (dockerResult?.items ?? []),
            simulators: await simulators,
            runtimes: await runtimes,
            dockerRunning: dockerResult?.running,
            disk: SystemInfo.disk(),
            trashSize: await trash,
            hasLocalSnapshots: await snapshots,
            hasFullDiskAccess: SystemInfo.hasFullDiskAccess()
        )
        result.files = await files
        let (apps, orphans) = await inventory
        result.apps = apps
        result.orphans = orphans
        result.storage = await storage
        result.journal = mark
        result.measuredCount = measuredCount
        result.duration = Date().timeIntervalSince(started)
        progress?(ScanProgress(phase: .done, message: "Done", fraction: 1))
        return result
    }

    public func scanProjects(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> [Project] {
        await scanProjects(reuse: nil, progress: progress).projects
    }

    func scanProjects(reuse: SizeReuse?, progress: (@Sendable (ScanProgress) -> Void)?) async -> (projects: [Project], measured: Int) {
        let finder = ProjectFinder(settings: settings) { count, path in
            progress?(ScanProgress(phase: .findingProjects, message: "Looking in \(path.abbreviatingHome)", fraction: nil))
            _ = count
        }
        let drafts = await offload { finder.find() }
        let processes = ProcessInspector.runningProcesses()

        progress?(ScanProgress(phase: .checkingGit, message: "Checking git status of \(drafts.count) projects", fraction: nil))
        let (filtered, gitStates) = await offload {
            let filtered = Self.applyGitIgnore(drafts)
            return (filtered, Self.inspectGit(filtered))
        }

        let allPaths = filtered.flatMap { $0.candidates.map(\.path) } + filtered.filter(\.isWorktree).map(\.path)
        var sizes: [String: SizeInfo] = [:]
        var toMeasure: [String] = []
        for path in allPaths {
            if let cached = reuse?.cached(path) {
                sizes[path] = cached
            } else {
                toMeasure.append(path)
            }
        }

        let total = toMeasure.count
        let measured = ProgressCounter()
        let fresh = await DirectorySizer.sizes(of: toMeasure) { _, _ in
            let done = measured.increment()
            progress?(ScanProgress(phase: .measuring, message: "Measuring \(done) of \(total) changed folders", fraction: Double(done) / Double(max(total, 1))))
        }
        sizes.merge(fresh) { _, new in new }

        var projects: [Project] = []
        for draft in filtered {
            let git = gitStates[draft.path]
            let user = ProcessInspector.user(of: draft.path, among: processes)
            let shell = ProcessInspector.shell(in: draft.path, among: processes)
            var project = Project(
                path: draft.path,
                name: (draft.path as NSString).lastPathComponent,
                ecosystems: draft.ecosystems,
                lastModified: draft.newestModified > 0 ? Date(timeIntervalSince1970: draft.newestModified) : nil,
                git: git,
                runningProcess: user?.name,
                hasLockfile: draft.hasLockfile
            )

            project.artifacts = draft.candidates.map { candidate in
                var artifact = Artifact(
                    path: candidate.path,
                    ruleID: candidate.rule.id,
                    name: candidate.rule.name,
                    tier: candidate.rule.tier,
                    rebuildHint: candidate.rule.rebuildHint,
                    size: sizes[candidate.path] ?? .zero
                )
                if let user = ProcessInspector.user(of: candidate.path, among: processes) ?? user {
                    artifact.blockedReason = "In use by \(user.name)"
                }
                artifact.warning = Self.warning(for: artifact, in: project)
                    ?? shell.map { "A terminal (\($0.name)) is open in this project." }
                return artifact
            }
            .filter { $0.size.allocated > 0 }
            .sorted { $0.size.reclaimable > $1.size.reclaimable }

            if draft.isWorktree, let git {
                project.artifacts.append(Artifact(
                    path: draft.path,
                    ruleID: "git-worktree",
                    name: "Git worktree",
                    tier: .review,
                    kind: .worktree,
                    rebuildHint: git.branch.map { "The branch \($0) is kept" },
                    size: sizes[draft.path] ?? .zero,
                    blockedReason: Self.worktreeBlocker(git, user: user)
                ))
            }

            if !project.artifacts.isEmpty { projects.append(project) }
        }
        return (projects.sorted { $0.reclaimable > $1.reclaimable }, total)
    }

    static func warning(for artifact: Artifact, in project: Project) -> String? {
        guard artifact.ruleID == "node-modules" else { return nil }
        if FileManager.default.fileExists(atPath: artifact.path + "/.pnpm"),
           artifact.size.reclaimable < artifact.size.allocated / 2 {
            return "Shares files with the pnpm store. Clean the pnpm store afterwards to free the rest."
        }
        if !project.hasLockfile {
            return "No lockfile, so a reinstall may pick newer package versions."
        }
        return nil
    }

    static func worktreeBlocker(_ git: GitState, user: RunningProcess?) -> String? {
        if let user { return "In use by \(user.name)" }
        if git.isLocked { return "Locked by git. A tool may still be using it." }
        if git.changedFiles < 0 { return "Couldn't read git status" }
        if git.changedFiles > 0 { return "Has \(git.changedFiles) uncommitted \(git.changedFiles == 1 ? "change" : "changes")" }
        guard let notInBase = git.commitsNotInBase else { return "Couldn't compare with a base branch" }
        if notInBase > 0 { return "Has \(notInBase) \(notInBase == 1 ? "commit" : "commits") not in \(git.baseBranch ?? "the base branch")" }
        if git.mainRepositoryPath == nil { return "Couldn't find the main repository" }
        return nil
    }

    /// Drops generic build folders (dist, build, target…) that git does not ignore.
    static func applyGitIgnore(_ drafts: [ProjectDraft]) -> [ProjectDraft] {
        Parallel.map(drafts, width: 8) { draft in
            var draft = draft
            let generic = draft.candidates.filter(\.rule.requiresGitIgnored).map(\.path)
            guard !generic.isEmpty else { return draft }
            let ignored = draft.isGitRoot ? GitInspector.ignoredPaths(generic, root: draft.path) : []
            draft.candidates.removeAll { $0.rule.requiresGitIgnored && !ignored.contains($0.path) }
            return draft
        }
    }

    static func inspectGit(_ drafts: [ProjectDraft]) -> [String: GitState] {
        let repositories = drafts.filter(\.isGitRoot)
        let states = Parallel.map(repositories, width: 8) { GitInspector.inspect($0.path, isWorktree: $0.isWorktree) }
        return Dictionary(uniqueKeysWithValues: zip(repositories.map(\.path), states))
    }
}

/// Runs blocking work on GCD instead of Swift's limited async thread pool.
func offload<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

/// Runs blocking work (processes, file I/O) on GCD so it never starves Swift's async thread pool.
enum Parallel {
    static func map<T, R>(_ items: [T], width: Int, _ transform: (T) -> R) -> [R] {
        var results = [R?](repeating: nil, count: items.count)
        let lock = NSLock()
        let chunks = max(1, min(width, items.count))
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            var index = chunk
            while index < items.count {
                let value = transform(items[index])
                lock.lock()
                results[index] = value
                lock.unlock()
                index += chunks
            }
        }
        return results.map { $0! }
    }
}

/// Sizes from the previous scan that FSEvents says haven't changed since.
struct SizeReuse: Sendable {
    let sizes: [String: SizeInfo]
    let changes: ChangeJournal.ChangeSet

    init?(previous: ScanResult?, settings: SweepSettings) {
        guard let previous, previous.roots == settings.roots else { return nil }
        let roots = Array(Set(settings.roots.map(\.expandingTilde) + [NSHomeDirectory()]))
        guard let changed = ChangeJournal.changes(since: previous.journal, under: roots) else { return nil }

        var sizes: [String: SizeInfo] = [:]
        for project in previous.projects {
            for artifact in project.artifacts { sizes[artifact.path] = artifact.size }
        }
        for app in previous.apps ?? [] {
            sizes[app.path] = app.size
            for leftover in app.leftovers { sizes[leftover.path] = leftover.size }
        }
        for orphan in previous.orphans ?? [] {
            for leftover in orphan.leftovers { sizes[leftover.path] = leftover.size }
        }
        for slice in previous.storage ?? [] {
            for (path, size) in slice.parts ?? [:] { sizes[path] = size }
        }
        self.sizes = sizes
        self.changes = ChangeJournal.ChangeSet(changed)
    }

    func cached(_ path: String) -> SizeInfo? {
        guard let size = sizes[path], !changes.touches(path), FileManager.default.fileExists(atPath: path) else { return nil }
        return size
    }

    func cached(_ path: String, _ previousValue: Int64?) -> Int64? {
        guard let previousValue, !changes.touches(path) else { return nil }
        return previousValue
    }
}

final class ProgressCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
