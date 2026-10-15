import Darwin
import Foundation

struct ProjectDraft {
    let path: String
    var ecosystems: [Ecosystem] = []
    var newestModified: TimeInterval = 0
    var hasLockfile = false
    var isGitRoot = false
    var isWorktree = false
    var candidates: [(path: String, rule: ArtifactRule)] = []

    mutating func merge(_ other: ProjectDraft) {
        for ecosystem in other.ecosystems where !ecosystems.contains(ecosystem) {
            ecosystems.append(ecosystem)
        }
        newestModified = max(newestModified, other.newestModified)
        hasLockfile = hasLockfile || other.hasLockfile
        isGitRoot = isGitRoot || other.isGitRoot
        isWorktree = isWorktree || other.isWorktree
        candidates += other.candidates
    }
}

/// Walks the scan roots and finds projects and their build folders without entering them.
struct ProjectFinder {
    let settings: SweepSettings
    let onProgress: (@Sendable (Int, String) -> Void)?
    var maxDepth = 14

    private let home = NSHomeDirectory()

    func find() -> [ProjectDraft] {
        let counter = WalkProgress(onProgress: onProgress)
        var drafts: [String: ProjectDraft] = [:]
        let lock = NSLock()

        for root in settings.roots.map(\.expandingTilde) {
            guard !isExcluded(root) else { continue }

            var state = WalkState()
            var frontier: [(path: String, project: String?, depth: Int)] = [(root, nil, 0)]
            for _ in 0..<3 where !frontier.isEmpty && frontier.count < 64 {
                var next: [(path: String, project: String?, depth: Int)] = []
                for item in frontier {
                    let fd = BulkDirectory.openDirectory(item.path)
                    guard fd >= 0 else { continue }
                    let children = visit(fd: fd, path: item.path, depth: item.depth, project: item.project, state: &state, counter: counter)
                    close(fd)
                    next += children.map { ($0.path, $0.project, item.depth + 1) }
                }
                frontier = next
            }
            merge(state.drafts, into: &drafts)

            DispatchQueue.concurrentPerform(iterations: frontier.count) { index in
                let item = frontier[index]
                var local = WalkState()
                let fd = BulkDirectory.openDirectory(item.path)
                guard fd >= 0 else { return }
                walk(fd: fd, path: item.path, depth: item.depth, project: item.project, state: &local, counter: counter)
                close(fd)
                lock.lock()
                merge(local.drafts, into: &drafts)
                lock.unlock()
            }
        }
        return Array(drafts.values)
    }

    private func merge(_ source: [String: ProjectDraft], into target: inout [String: ProjectDraft]) {
        for (path, draft) in source {
            if var existing = target[path] {
                existing.merge(draft)
                target[path] = existing
            } else {
                target[path] = draft
            }
        }
    }

    private struct WalkState {
        var drafts: [String: ProjectDraft] = [:]

        mutating func update(_ path: String, _ change: (inout ProjectDraft) -> Void) {
            var draft = drafts[path] ?? ProjectDraft(path: path)
            change(&draft)
            drafts[path] = draft
        }
    }

    private func walk(fd: Int32, path: String, depth: Int, project: String?, state: inout WalkState, counter: WalkProgress) {
        let children = visit(fd: fd, path: path, depth: depth, project: project, state: &state, counter: counter)
        for child in children {
            let childFD = BulkDirectory.openDirectory((child.path as NSString).lastPathComponent, in: fd)
            guard childFD >= 0 else { continue }
            walk(fd: childFD, path: child.path, depth: depth + 1, project: child.project, state: &state, counter: counter)
            close(childFD)
        }
    }

    /// Records what this folder contributes and returns the subfolders still to walk.
    private func visit(fd: Int32, path: String, depth: Int, project: String?, state: inout WalkState, counter: WalkProgress) -> [(path: String, project: String?)] {
        counter.tick(path)

        var entries: [DirEntry] = []
        BulkDirectory.forEach(in: fd) { entries.append($0) }
        let names = Set(entries.map(\.name))

        var current = project
        let gitEntry = entries.first { $0.name == ".git" }
        let ecosystems = Rules.ecosystems(in: names)
        let canBeProject = path != home

        if let gitEntry, canBeProject {
            let kind = gitEntry.kind == .file ? Self.gitFileKind(path) : .repository
            if kind != .submodule || current == nil {
                current = path
                state.update(path) {
                    $0.isGitRoot = true
                    $0.isWorktree = kind == .worktree
                }
            }
        } else if current == nil, !ecosystems.isEmpty, canBeProject {
            current = path
        }

        if let current {
            let hasLockfile = !names.isDisjoint(with: Rules.lockfiles)
            let newest = entries.lazy.filter { $0.kind == .file && $0.name != ".DS_Store" }.map(\.modified).max() ?? 0
            state.update(current) {
                for ecosystem in ecosystems where !$0.ecosystems.contains(ecosystem) {
                    $0.ecosystems.append(ecosystem)
                }
                $0.hasLockfile = $0.hasLockfile || hasLockfile
                $0.newestModified = max($0.newestModified, newest)
            }
        }

        var next: [(path: String, project: String?)] = []
        for entry in entries where entry.kind == .directory {
            let name = entry.name
            let childPath = path == "/" ? "/" + name : path + "/" + name

            if Rules.skippedDirectories.contains(name) { continue }
            if path == home, Rules.skippedHomeDirectories.contains(name) { continue }
            if Rules.packageExtensions.contains((name as NSString).pathExtension.lowercased()) { continue }
            if isExcluded(childPath) { continue }

            if let rule = Self.rule(for: name, siblings: names) {
                let owner = current ?? path
                if current == nil, !canBeProject { continue }
                state.update(owner) { $0.candidates.append((childPath, rule)) }
                continue
            }

            if name.hasPrefix("."), current == nil { continue }
            if depth + 1 > maxDepth { continue }
            next.append((childPath, current))
        }
        return next
    }

    private func isExcluded(_ path: String) -> Bool {
        settings.excludedPaths.contains { path.isInside($0.expandingTilde) }
    }

    static func rule(for directory: String, siblings: Set<String>) -> ArtifactRule? {
        guard let rules = Rules.rulesByDirectory[directory] else { return nil }
        let matching = rules.filter { $0.matches(siblings: siblings) }
        return matching.first { !$0.markers.isEmpty } ?? matching.first
    }

    enum GitFileKind { case repository, worktree, submodule }

    static func gitFileKind(_ directory: String) -> GitFileKind {
        guard let contents = try? String(contentsOfFile: directory + "/.git", encoding: .utf8) else { return .worktree }
        if contents.contains("/modules/") { return .submodule }
        return .worktree
    }
}

private final class WalkProgress: @unchecked Sendable {
    private var count = 0
    private var lastReport = Date.distantPast
    private let lock = NSLock()
    private let onProgress: (@Sendable (Int, String) -> Void)?

    init(onProgress: (@Sendable (Int, String) -> Void)?) {
        self.onProgress = onProgress
    }

    func tick(_ path: String) {
        guard let onProgress else { return }
        lock.lock()
        count += 1
        let now = Date()
        let shouldReport = now.timeIntervalSince(lastReport) > 0.1
        if shouldReport { lastReport = now }
        let snapshot = count
        lock.unlock()
        if shouldReport { onProgress(snapshot, path) }
    }
}
