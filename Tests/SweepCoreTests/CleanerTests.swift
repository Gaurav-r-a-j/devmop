import Foundation
import Testing
@testable import SweepCore

@Suite(.serialized) struct CleanerTests {
    private func withHistory<T>(_ fx: Fixture, _ body: () async throws -> T) async rethrows -> T {
        History.overrideDirectory = URL(fileURLWithPath: fx.dir("history"))
        defer { History.overrideDirectory = nil }
        return try await body()
    }

    private func worktreeFixture(_ fx: Fixture) -> (repo: String, worktree: String)? {
        guard Git.available else { return nil }
        let repo = fx.dir("repo")
        Git.initRepo(repo)
        fx.write("repo/.gitignore", "node_modules/\n")
        fx.write("repo/package.json", "{}")
        Git.commitAll(repo)
        let worktree = fx.path("wt")
        guard Git.run(["worktree", "add", "-q", "-b", "feature", worktree], in: repo).succeeded else { return nil }
        return (repo, worktree)
    }

    private func worktreeArtifact(_ path: String) -> Artifact {
        Artifact(path: path, ruleID: "git-worktree", name: "Git worktree", tier: .review, kind: .worktree, rebuildHint: nil)
    }

    @Test func recheckAcceptsValidFolder() {
        let fx = Fixture()
        let modules = fx.dir("app/node_modules")
        #expect(Cleaner.recheck(folderArtifact(modules), in: sampleProject(fx.path("app"))) == nil)
    }

    @Test func recheckRefusesSymlink() throws {
        let fx = Fixture()
        let target = fx.dir("elsewhere")
        fx.dir("app")
        try FileManager.default.createSymbolicLink(atPath: fx.path("app/node_modules"), withDestinationPath: target)
        let problem = Cleaner.recheck(folderArtifact(fx.path("app/node_modules")), in: sampleProject(fx.path("app")))
        #expect(problem == "No longer a folder")
    }

    @Test func recheckRefusesOutsideProject() {
        let fx = Fixture()
        let modules = fx.dir("other/node_modules")
        fx.dir("app")
        #expect(Cleaner.recheck(folderArtifact(modules), in: sampleProject(fx.path("app"))) == "Outside its project")
        let sibling = fx.dir("app-two/node_modules")
        #expect(Cleaner.recheck(folderArtifact(sibling), in: sampleProject(fx.path("app"))) == "Outside its project")
    }

    @Test func recheckRefusesProjectFolder() {
        let fx = Fixture()
        let app = fx.dir("node_modules")
        #expect(Cleaner.recheck(folderArtifact(app), in: sampleProject(app)) == "Refusing to delete a project folder")
    }

    @Test func recheckRefusesRenamedFolder() {
        let fx = Fixture()
        let vendor = fx.dir("app/vendor")
        #expect(Cleaner.recheck(folderArtifact(vendor), in: sampleProject(fx.path("app"))) == "Folder name no longer matches its rule")
        #expect(Cleaner.recheck(folderArtifact(fx.path("app/missing")), in: sampleProject(fx.path("app"))) == "Already gone")
    }

    @Test func cleanDeletesNodeModules() async {
        let fx = Fixture()
        fx.file("app/node_modules/a/index.js", bytes: 20_000)
        fx.file("app/src/index.js")
        let modules = fx.path("app/node_modules")
        let artifact = folderArtifact(modules, size: DirectorySizer.size(of: modules))
        let project = sampleProject(fx.path("app"), artifacts: [artifact])

        let report = await withHistory(fx) { await Cleaner.clean([.artifact(artifact, project: project)], mode: .permanent) }
        #expect(report.outcomes.count == 1)
        #expect(report.outcomes.first?.succeeded == true)
        #expect(report.cleanedBytes == artifact.size.reclaimable)
        #expect(report.cleanedBytes > 0)
        #expect(report.trashedPaths.isEmpty)
        #expect(!fx.exists("app/node_modules"))
        #expect(fx.exists("app/src/index.js"))
    }

    @Test func blockedArtifactIsKept() async {
        let fx = Fixture()
        fx.file("app/node_modules/a/index.js")
        let artifact = folderArtifact(fx.path("app/node_modules"), size: SizeInfo(allocated: 4096, reclaimable: 4096), blockedReason: "In use by node")
        let project = sampleProject(fx.path("app"), artifacts: [artifact])

        let report = await withHistory(fx) { await Cleaner.clean([.artifact(artifact, project: project)], mode: .permanent) }
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.message == "In use by node")
        #expect(report.cleanedBytes == 0)
        #expect(fx.exists("app/node_modules/a/index.js"))
    }

    @Test func worktreeSelectionSkipsNestedFolder() async {
        let fx = Fixture()
        guard let (_, worktree) = worktreeFixture(fx) else { return }
        fx.file("wt/node_modules/a/index.js")
        let modules = folderArtifact(worktree + "/node_modules", size: SizeInfo(allocated: 4096, reclaimable: 4096))
        let tree = worktreeArtifact(worktree)
        let project = sampleProject(worktree, artifacts: [modules, tree])

        let report = await withHistory(fx) {
            await Cleaner.clean([.artifact(modules, project: project), .artifact(tree, project: project)], mode: .permanent)
        }
        #expect(report.outcomes.map(\.targetID) == ["artifact:\(worktree)"])
        #expect(report.outcomes.first?.succeeded == true, "\(report.outcomes.first?.message ?? "")")
        #expect(!fx.exists("wt"))
    }

    @Test func cleanWorktreeIsRemovedAndDirtyIsRefused() async {
        let fx = Fixture()
        guard let (repo, worktree) = worktreeFixture(fx) else { return }
        let tree = worktreeArtifact(worktree)
        let project = sampleProject(worktree, artifacts: [tree])

        fx.write("wt/notes.txt", "unsaved")
        let refused = await withHistory(fx) { await Cleaner.clean([.artifact(tree, project: project)], mode: .permanent) }
        #expect(refused.outcomes.first?.succeeded == false)
        #expect(refused.outcomes.first?.message?.contains("uncommitted") == true)
        #expect(fx.exists("wt/notes.txt"))

        try? FileManager.default.removeItem(atPath: fx.path("wt/notes.txt"))
        let removed = await withHistory(fx) { await Cleaner.clean([.artifact(tree, project: project)], mode: .permanent) }
        #expect(removed.outcomes.first?.succeeded == true, "\(removed.outcomes.first?.message ?? "")")
        #expect(!fx.exists("wt"))
        #expect(!Git.run(["worktree", "list"], in: repo).output.contains(worktree))
        #expect(fx.exists("repo/package.json"))
    }

    @Test func historyRecordsRun() async {
        let fx = Fixture()
        fx.file("app/node_modules/a/index.js")
        let artifact = folderArtifact(fx.path("app/node_modules"), size: SizeInfo(allocated: 4096, reclaimable: 4096))
        let project = sampleProject(fx.path("app"), artifacts: [artifact])

        let history = await withHistory(fx) { () -> [CleanReport] in
            #expect(History.load().isEmpty)
            _ = await Cleaner.clean([.artifact(artifact, project: project)], mode: .permanent)
            _ = await Cleaner.clean([], mode: .permanent)
            return History.load()
        }
        #expect(history.count == 1)
        #expect(history.first?.mode == .permanent)
        #expect(history.first?.outcomes.first?.targetID == "artifact:\(artifact.path)")
        #expect(history.first?.outcomes.first?.succeeded == true)
        #expect(fx.exists("history/history.jsonl"))
    }

    @Test func scanCacheRoundTrips() async {
        let fx = Fixture()
        let loaded = await withHistory(fx) { () -> ScanResult? in
            ScanCache.save(ScanResult(roots: [fx.root], projects: [sampleProject(fx.path("app"))], trashSize: 12))
            return ScanCache.load()
        }
        #expect(loaded?.roots == [fx.root])
        #expect(loaded?.projects.first?.path == fx.path("app"))
        #expect(loaded?.trashSize == 12)
    }
}
