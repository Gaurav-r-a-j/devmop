import Darwin
import Foundation
import Testing
@testable import SweepCore

struct SafetyTests {
    @Test func protectedLocationsAreRefused() {
        let home = NSHomeDirectory()
        for path in ["/", "/Users", "/System/Library", home, "\(home)/Library", "\(home)/Documents", "\(home)/Desktop",
                     "\(home)/Library/Mobile Documents/com~apple~CloudDocs/app/node_modules",
                     "\(home)/Library/CloudStorage/Dropbox/app/node_modules",
                     "\(home)/code/app/.git/node_modules", "/tmp"] {
            #expect(Cleaner.unsafeLocation(path) != nil, "\(path) should be protected")
        }
        #expect(Cleaner.unsafeLocation("\(home)/code/app/node_modules") == nil)
        #expect(Cleaner.unsafeLocation("\(home)/code/../Library") != nil)
    }

    @Test func cacheFolderMustBeRealFolderInsideHome() throws {
        let fx = Fixture()
        let home = fx.dir("home")
        let cache = fx.dir("home/cache")
        fx.dir("elsewhere/data")
        try FileManager.default.createSymbolicLink(atPath: fx.path("home/linked"), withDestinationPath: fx.path("elsewhere"))
        fx.file("home/plain.txt")

        #expect(Cleaner.unsafeCacheFolder(cache, home: home) == nil)
        #expect(Cleaner.unsafeCacheFolder(fx.path("home/linked"), home: home) != nil)
        #expect(Cleaner.unsafeCacheFolder(fx.path("home/plain.txt"), home: home) != nil)
        #expect(Cleaner.unsafeCacheFolder(fx.path("home/missing"), home: home) != nil)
        #expect(Cleaner.unsafeCacheFolder(fx.path("elsewhere/data"), home: home) != nil)
        #expect(Cleaner.unsafeCacheFolder(home, home: home) != nil)
    }

    @Test func storedCachePathsAreNeverTrusted() {
        let tampered = CacheItem(id: "npm", name: "npm cache", group: .packageManagers, symbol: "", detail: "",
                                 paths: ["/Users", NSHomeDirectory() + "/Documents"], tier: .safe,
                                 method: .command(tool: "rm", arguments: ["-rf", "/"]), toolPath: "/bin/rm")
        let trusted = Cleaner.trustedCache(tampered)
        #expect(trusted?.paths.contains("/Users") == false)
        #expect(trusted?.paths.allSatisfy { $0.hasSuffix("/.npm/_cacache") } == true)
        if case .command(let tool, let arguments) = trusted?.method {
            #expect(tool == "npm")
            #expect(arguments == ["cache", "clean", "--force"])
        } else {
            Issue.record("npm should clean with its own command")
        }
        #expect(trusted?.toolPath != "/bin/rm")

        let unknown = CacheItem(id: "made-up", name: "x", group: .languages, symbol: "", detail: "", paths: ["/"], tier: .safe, method: .deletePaths)
        #expect(Cleaner.trustedCache(unknown) == nil)

        let fakeDocker = CacheItem(id: "docker-everything", name: "x", group: .docker, symbol: "", detail: "", paths: [], tier: .safe,
                                   method: .command(tool: "docker", arguments: ["system", "prune", "-a", "--volumes", "-f"]))
        #expect(Cleaner.trustedCache(fakeDocker) == nil)
    }

    @Test func pureCachesAreEmptiedWithoutRunningTools() {
        for id in ["bun", "yarn", "pip"] {
            #expect(CacheCatalog.definitions().first { $0.id == id }?.method == .deleteContents, "\(id)")
        }
    }

    @Test func toolsRunInAnEmptyNeutralFolder() {
        let result = Shell.run("/bin/pwd", [])
        let reported = Fixture.resolved(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(reported == Fixture.resolved(Shell.neutralDirectory))
        #expect(reported != "/")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: Shell.neutralDirectory)) ?? []
        #expect(!contents.contains("package.json"))
    }

    @Test func recheckRefusesWhenProjectFileIsGone() {
        let fx = Fixture()
        let project = fx.dir("app")
        fx.write("app/package.json", "{}")
        let next = fx.dir("app/.next")
        let artifact = folderArtifact(next, ruleID: "next")
        #expect(Cleaner.recheck(artifact, in: sampleProject(project)) == nil)

        try? FileManager.default.removeItem(atPath: fx.path("app/package.json"))
        #expect(Cleaner.recheck(artifact, in: sampleProject(project)) != nil)
    }

    @Test func recheckRefusesGenericFolderGitNoLongerIgnores() {
        guard Git.available else { return }
        let fx = Fixture()
        let project = fx.dir("app")
        Git.initRepo(project)
        fx.write("app/package.json", "{}")
        fx.write("app/.gitignore", "dist/\n")
        fx.file("app/dist/bundle.js")
        let artifact = folderArtifact(fx.path("app/dist"), ruleID: "node-dist")
        #expect(Cleaner.recheck(artifact, in: sampleProject(project)) == nil)

        fx.write("app/.gitignore", "")
        #expect(Cleaner.recheck(artifact, in: sampleProject(project)) != nil)
    }

    @Test func recheckRefusesMainRepositoryAsWorktree() {
        guard Git.available else { return }
        let fx = Fixture()
        let repo = fx.dir("repo")
        Git.initRepo(repo)
        let artifact = Artifact(path: repo, ruleID: "git-worktree", name: "Git worktree", tier: .review, kind: .worktree, rebuildHint: nil)
        #expect(Cleaner.recheck(artifact, in: sampleProject(repo)) != nil)
    }

    @Test func emptyFromTrashOnlyTouchesTrash() {
        let fx = Fixture()
        let outside = fx.file("keep.txt")
        let removed = Cleaner.emptyFromTrash([(outside, Cleaner.identity(of: outside)), (SystemInfo.trashPath, nil),
                                              (SystemInfo.trashPath + "/../Documents", nil)])
        #expect(removed.removed == 0)
        #expect(removed.freed == 0)
        #expect(fx.exists("keep.txt"))
    }

    @Test func concurrentCommandsNeverLoseOutput() {
        let slow = DispatchQueue.global()
        slow.async { _ = Shell.run("/bin/sleep", ["3"]) }
        let results = Parallel.map(Array(0..<40), width: 16) { index in
            Shell.run("/bin/echo", ["line-\(index)"], timeout: 10)
        }
        for (index, result) in results.enumerated() {
            #expect(result.succeeded)
            #expect(result.output == "line-\(index)\n")
        }
    }

    @Test func failedAndTimedOutCommandsAreNotSuccess() {
        #expect(!Shell.run("/usr/bin/false", []).succeeded)
        #expect(Shell.run("/bin/sh", ["-c", "exit 3"]).status == 3)
        let slow = Shell.run("/bin/sleep", ["5"], timeout: 0.5)
        #expect(slow.timedOut)
        #expect(!slow.succeeded)
        #expect(!Shell.run("/no/such/tool", []).succeeded)
    }

    @Test func pathChecksIgnoreCaseLikeAPFS() {
        let home = NSHomeDirectory()
        #expect("\(home)/library/Mobile Documents/x".isInside("\(home)/Library/Mobile Documents"))
        #expect(Cleaner.unsafeLocation("\(home)/LIBRARY/mobile documents/com~apple~CloudDocs/a/node_modules") != nil)
        #expect(Cleaner.unsafeLocation("\(home)/library") != nil)
        #expect(Cleaner.unsafeLocation("\(home)/code/app/.GIT/x") != nil)
    }

    @Test func nestedScanRootsAreWalkedOnce() {
        let roots = ProjectFinder.distinctRoots(["/Users/a", "/Users/a/code", "/Users/b/", "/Users/b"])
        #expect(roots == ["/Users/a", "/Users/b"])
    }

    @Test func simulatorIDsMustBeRealUUIDs() {
        #expect(!Cleaner.isUUID("all"))
        #expect(!Cleaner.isUUID("booted"))
        #expect(Cleaner.isUUID("E5168CAF-7C25-473B-845A-B7CDA6949A61"))
    }

    @Test func vendorFoldersAreNeverMatchedByAppName() {
        let fx = Fixture()
        let library = fx.dir("Library")
        fx.dir("Library/Application Support/Google")
        let found = AppInventory.leftovers(bundleID: "com.example.google", name: "Google", library: library)
        #expect(found.isEmpty)
    }

    @Test func userFilesMustLiveInPersonalFoldersWithoutHiddenParts() {
        let fx = Fixture()
        let secret = fx.file(".ssh/id_ed25519", bytes: 2_000)
        let hidden = fx.file("Documents/.private/notes.bin", bytes: 2_000)
        for path in [secret, hidden] {
            var st = stat()
            lstat(path, &st)
            let file = UserFile(path: path, name: "x", allocated: Int64(st.st_blocks) * 512, reclaimable: 0,
                                modified: nil, lastOpened: nil, reasons: [.large])
            #expect(UserFiles.recheck(file, home: fx.root) == "Outside your personal folders", "\(path)")
        }
    }
}
