import Foundation

public enum GitInspector {
    public static func inspect(_ path: String, isWorktree: Bool) -> GitState {
        var state = GitState(isWorktree: isWorktree)

        let head = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)
        if head.succeeded {
            state.branch = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let status = Shell.git(["status", "--porcelain", "--untracked-files=normal"], in: path, timeout: 30)
        if status.succeeded {
            state.changedFiles = status.output.split(separator: "\n").count
        } else if status.timedOut {
            state.changedFiles = -1
        }

        let log = Shell.git(["log", "-1", "--format=%ct"], in: path)
        if log.succeeded, let seconds = TimeInterval(log.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            state.lastCommitDate = Date(timeIntervalSince1970: seconds)
        }

        let remotes = Shell.git(["remote"], in: path)
        if remotes.succeeded, !remotes.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let unpushed = Shell.git(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: path)
            if unpushed.succeeded { state.unpushedCommits = Int(unpushed.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        if isWorktree {
            state.isLocked = worktreeIsLocked(path)
            let common = Shell.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
            if common.succeeded {
                let gitDir = common.output.trimmingCharacters(in: .whitespacesAndNewlines)
                state.mainRepositoryPath = gitDir.hasSuffix("/.git") ? String(gitDir.dropLast(5)) : gitDir
            }
            if let base = baseBranch(in: path) {
                state.baseBranch = base
                if base != state.branch {
                    let cherry = Shell.git(["cherry", base, "HEAD"], in: path)
                    if cherry.succeeded {
                        state.commitsNotInBase = cherry.output.split(separator: "\n").filter { $0.hasPrefix("+") }.count
                    }
                } else {
                    state.commitsNotInBase = 0
                }
            }
        }
        return state
    }

    /// Paths from `candidates` that git ignores in the repository at `root`.
    public static func ignoredPaths(_ candidates: [String], root: String) -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        let list = candidates.joined(separator: "\n")
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("devmop-ignore-\(UUID().uuidString)")
        guard (try? list.write(to: input, atomically: true, encoding: .utf8)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: input) }

        let result = Shell.git(["-c", "core.quotepath=off", "check-ignore", "--stdin"], in: root, timeout: 20, stdin: input)
        return Set(result.output.split(separator: "\n").map { line in
            let path = String(line)
            return path.hasPrefix("/") ? path : root + "/" + path
        })
    }

    private static func worktreeIsLocked(_ path: String) -> Bool {
        guard let contents = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return false }
        var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitDir.hasPrefix("/") { gitDir = path + "/" + gitDir }
        return FileManager.default.fileExists(atPath: gitDir + "/locked")
    }

    private static func baseBranch(in path: String) -> String? {
        let originHead = Shell.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: path)
        if originHead.succeeded {
            let remote = originHead.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let local = remote.replacingOccurrences(of: "origin/", with: "")
            if Shell.git(["rev-parse", "--verify", "--quiet", local], in: path).succeeded { return local }
            return remote
        }
        for candidate in ["main", "master", "develop"] where Shell.git(["rev-parse", "--verify", "--quiet", candidate], in: path).succeeded {
            return candidate
        }
        return nil
    }
}
