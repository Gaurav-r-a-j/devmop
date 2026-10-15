import Darwin
import Foundation
@testable import SweepCore

/// A throwaway folder under the temp directory, removed when released.
final class Fixture {
    let root: String

    init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sweepcore-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = Self.resolved(base.path)
    }

    deinit {
        let temp = Self.resolved(FileManager.default.temporaryDirectory.path)
        guard root.isInside(temp), root != temp else { return }
        restorePermissions(root)
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String {
        relative.isEmpty ? root : root + "/" + relative
    }

    @discardableResult
    func dir(_ relative: String) -> String {
        let full = path(relative)
        try! FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 64) -> String {
        write(relative, data: Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))
    }

    @discardableResult
    func write(_ relative: String, _ text: String) -> String {
        write(relative, data: Data(text.utf8))
    }

    @discardableResult
    func write(_ relative: String, data: Data) -> String {
        let full = path(relative)
        try! FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! data.write(to: URL(fileURLWithPath: full))
        return full
    }

    func exists(_ relative: String) -> Bool {
        var st = stat()
        return lstat(path(relative), &st) == 0
    }

    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    private func restorePermissions(_ directory: String) {
        chmod(directory, 0o755)
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for child in children {
            let full = directory + "/" + child
            var st = stat()
            if lstat(full, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { restorePermissions(full) }
        }
    }
}

enum Git {
    static var available: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") && run(["--version"], in: "/").succeeded }

    @discardableResult
    static func run(_ arguments: [String], in directory: String) -> ShellResult {
        Shell.run("/usr/bin/git", ["-C", directory, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments, timeout: 30)
    }

    static func initRepo(_ directory: String) {
        run(["init", "-q", "-b", "main"], in: directory)
        run(["config", "user.name", "Sweep Tests"], in: directory)
        run(["config", "user.email", "tests@example.com"], in: directory)
    }

    static func commitAll(_ directory: String, message: String = "commit") {
        run(["add", "-A"], in: directory)
        run(["commit", "-q", "-m", message], in: directory)
    }
}

/// Sum of lstat st_blocks over every non-directory entry, counting hardlinks once.
func expectedAllocated(_ path: String) -> Int64 {
    var seen = Set<UInt64>()
    func visit(_ path: String) -> Int64 {
        var total: Int64 = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            let full = path + "/" + name
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            if st.st_mode & S_IFMT == S_IFDIR {
                total += visit(full)
            } else if st.st_nlink <= 1 || seen.insert(UInt64(st.st_ino)).inserted {
                total += Int64(st.st_blocks) * 512
            }
        }
        return total
    }
    return visit(path)
}

func sampleProject(_ path: String, artifacts: [Artifact] = [], hasLockfile: Bool = true) -> Project {
    Project(path: path, name: (path as NSString).lastPathComponent, ecosystems: [.node], artifacts: artifacts, hasLockfile: hasLockfile)
}

func folderArtifact(_ path: String, ruleID: String = "node-modules", size: SizeInfo = .zero, blockedReason: String? = nil) -> Artifact {
    let rule = Rules.artifacts.first { $0.id == ruleID }
    return Artifact(path: path, ruleID: ruleID, name: rule?.name ?? ruleID, tier: rule?.tier ?? .rebuildable,
                    rebuildHint: rule?.rebuildHint, size: size, blockedReason: blockedReason)
}
