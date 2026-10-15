import Foundation
import Testing
@testable import SweepCore

@Suite struct WorktreeBlockerTests {
    private let clean = GitState(isWorktree: true, changedFiles: 0, commitsNotInBase: 0, baseBranch: "main", mainRepositoryPath: "/repo")

    @Test func cleanWorktreeHasNoBlocker() {
        #expect(Scanner.worktreeBlocker(clean, user: nil) == nil)
    }

    @Test func inUseBlocks() {
        let user = RunningProcess(pid: 42, name: "node", workingDirectory: "/repo-wt")
        #expect(Scanner.worktreeBlocker(clean, user: user) == "In use by node")
    }

    @Test func lockedBlocks() {
        var git = clean
        git.isLocked = true
        #expect(Scanner.worktreeBlocker(git, user: nil)?.contains("Locked") == true)
    }

    @Test func dirtyBlocks() {
        var git = clean
        git.changedFiles = 1
        #expect(Scanner.worktreeBlocker(git, user: nil) == "Has 1 uncommitted change")
        git.changedFiles = 3
        #expect(Scanner.worktreeBlocker(git, user: nil) == "Has 3 uncommitted changes")
        git.changedFiles = -1
        #expect(Scanner.worktreeBlocker(git, user: nil) == "Couldn't read git status")
    }

    @Test func commitsNotInBaseBlock() {
        var git = clean
        git.commitsNotInBase = 2
        #expect(Scanner.worktreeBlocker(git, user: nil) == "Has 2 commits not in main")
        git.commitsNotInBase = 1
        #expect(Scanner.worktreeBlocker(git, user: nil) == "Has 1 commit not in main")
    }

    @Test func missingBaseBlocks() {
        var git = clean
        git.commitsNotInBase = nil
        git.baseBranch = nil
        #expect(Scanner.worktreeBlocker(git, user: nil) == "Couldn't compare with a base branch")
    }

    @Test func missingMainRepositoryBlocks() {
        var git = clean
        git.mainRepositoryPath = nil
        #expect(Scanner.worktreeBlocker(git, user: nil) == "Couldn't find the main repository")
    }
}

@Suite struct WarningTests {
    @Test func nodeModulesWithoutLockfileWarns() {
        let fx = Fixture()
        let modules = fx.dir("app/node_modules")
        let artifact = folderArtifact(modules, size: SizeInfo(allocated: 1_000, reclaimable: 1_000))
        let warning = Scanner.warning(for: artifact, in: sampleProject(fx.path("app"), hasLockfile: false))
        #expect(warning?.contains("lockfile") == true)
        #expect(Scanner.warning(for: artifact, in: sampleProject(fx.path("app"), hasLockfile: true)) == nil)
    }

    @Test func pnpmSharedNodeModulesWarns() {
        let fx = Fixture()
        let modules = fx.dir("app/node_modules")
        fx.dir("app/node_modules/.pnpm")
        let project = sampleProject(fx.path("app"), hasLockfile: true)

        let shared = folderArtifact(modules, size: SizeInfo(allocated: 10_000, reclaimable: 1_000))
        #expect(Scanner.warning(for: shared, in: project)?.contains("pnpm store") == true)

        let owned = folderArtifact(modules, size: SizeInfo(allocated: 10_000, reclaimable: 9_000))
        #expect(Scanner.warning(for: owned, in: project) == nil)
    }

    @Test func otherRulesNeverWarn() {
        let fx = Fixture()
        let artifact = folderArtifact(fx.dir("app/.next"), ruleID: "next", size: SizeInfo(allocated: 1, reclaimable: 1))
        #expect(Scanner.warning(for: artifact, in: sampleProject(fx.path("app"), hasLockfile: false)) == nil)
    }
}

@Suite struct GitInspectorTests {
    @Test func untrackedFileAndCommitDate() {
        guard Git.available else { return }
        let fx = Fixture()
        let repo = fx.dir("repo")
        Git.initRepo(repo)

        var state = GitInspector.inspect(repo, isWorktree: false)
        #expect(state.lastCommitDate == nil)
        #expect(state.changedFiles == 0)

        fx.write("repo/README.md", "hi")
        state = GitInspector.inspect(repo, isWorktree: false)
        #expect(state.changedFiles == 1)

        Git.commitAll(repo)
        state = GitInspector.inspect(repo, isWorktree: false)
        #expect(state.changedFiles == 0)
        #expect(state.branch == "main")
        #expect(state.lastCommitDate != nil)
        #expect(state.unpushedCommits == nil)
        #expect(state.isWorktree == false)
    }

    @Test func linkedWorktreeState() {
        guard Git.available else { return }
        let fx = Fixture()
        let repo = fx.dir("repo")
        Git.initRepo(repo)
        fx.write("repo/README.md", "hi")
        Git.commitAll(repo)
        #expect(Git.run(["worktree", "add", "-q", "-b", "feature", fx.path("wt")], in: repo).succeeded)
        let worktree = fx.path("wt")

        var state = GitInspector.inspect(worktree, isWorktree: true)
        #expect(state.isWorktree)
        #expect(state.branch == "feature")
        #expect(state.baseBranch == "main")
        #expect(state.mainRepositoryPath.map(Fixture.resolved) == Fixture.resolved(repo))
        #expect(state.commitsNotInBase == 0)
        #expect(state.isLocked == false)
        #expect(Scanner.worktreeBlocker(state, user: nil) == nil)

        fx.write("wt/feature.txt", "work")
        Git.commitAll(worktree, message: "feature work")
        state = GitInspector.inspect(worktree, isWorktree: true)
        #expect(state.commitsNotInBase == 1)

        #expect(Git.run(["worktree", "lock", worktree], in: repo).succeeded)
        state = GitInspector.inspect(worktree, isWorktree: true)
        #expect(state.isLocked)
        Git.run(["worktree", "unlock", worktree], in: repo)
    }

    @Test func ignoredPathsReportsOnlyIgnored() {
        guard Git.available else { return }
        let fx = Fixture()
        let repo = fx.dir("repo")
        Git.initRepo(repo)
        fx.write("repo/.gitignore", "dist/\n*.log\n")
        fx.file("repo/dist/a.js")
        fx.file("repo/build/a.js")
        fx.file("repo/my folder/out.log")

        let candidates = [fx.path("repo/dist"), fx.path("repo/build"), fx.path("repo/my folder/out.log")]
        let ignored = GitInspector.ignoredPaths(candidates, root: repo)
        #expect(ignored == [fx.path("repo/dist"), fx.path("repo/my folder/out.log")])
        #expect(GitInspector.ignoredPaths([], root: repo).isEmpty)
    }
}

@Suite struct ParallelTests {
    @Test func mapPreservesOrderAndCoversAll() {
        let items = Array(0..<1_000)
        #expect(Parallel.map(items, width: 7) { $0 * 2 } == items.map { $0 * 2 })
        #expect(Parallel.map(items, width: 1) { "\($0)" } == items.map { "\($0)" })
        #expect(Parallel.map([Int](), width: 4) { $0 }.isEmpty)
        #expect(Parallel.map([5], width: 64) { $0 + 1 } == [6])
    }

    @Test func offloadReturnsValue() async {
        let value = await offload { (1...100).reduce(0, +) }
        #expect(value == 5050)
    }
}
