import Foundation
import Testing
@testable import SweepCore

@Suite struct FinderTests {
    private func find(_ fx: Fixture, excluded: [String] = []) -> [String: ProjectDraft] {
        let finder = ProjectFinder(settings: SweepSettings(roots: [fx.root], excludedPaths: excluded), onProgress: nil)
        return Dictionary(uniqueKeysWithValues: finder.find().map { ($0.path, $0) })
    }

    private func candidatePaths(_ draft: ProjectDraft?) -> Set<String> {
        Set(draft?.candidates.map(\.path) ?? [])
    }

    @Test func nodeProjectWithLockfile() async throws {
        let fx = Fixture()
        fx.write("web/package.json", "{}")
        fx.write("web/pnpm-lock.yaml", "lockfileVersion: 9")
        fx.file("web/node_modules/left-pad/index.js", bytes: 4_000)

        let projects = await Scanner(settings: SweepSettings(roots: [fx.root])).scanProjects()
        #expect(projects.count == 1)
        let project = try #require(projects.first)
        #expect(project.path == fx.path("web"))
        #expect(project.ecosystems == [.node])
        #expect(project.hasLockfile)
        #expect(project.artifacts.map(\.ruleID) == ["node-modules"])
        #expect(project.artifacts.first?.path == fx.path("web/node_modules"))
        #expect(project.artifacts.first?.warning == nil)
        #expect((project.artifacts.first?.size.allocated ?? 0) > 0)
    }

    @Test func workspacePackagesGroupIntoGitRoot() {
        let fx = Fixture()
        fx.dir("mono/.git")
        fx.write("mono/package.json", "{}")
        fx.file("mono/node_modules/x/index.js")
        fx.write("mono/packages/a/package.json", "{}")
        fx.file("mono/packages/a/node_modules/y/index.js")

        let drafts = find(fx)
        #expect(drafts.count == 1)
        let root = drafts[fx.path("mono")]
        #expect(root?.isGitRoot == true)
        #expect(candidatePaths(root) == [fx.path("mono/node_modules"), fx.path("mono/packages/a/node_modules")])
    }

    @Test func doesNotDescendIntoNodeModules() {
        let fx = Fixture()
        fx.write("app/package.json", "{}")
        fx.write("app/node_modules/pkg/package.json", "{}")
        fx.file("app/node_modules/pkg/node_modules/dep/index.js")
        fx.write("app/node_modules/pkg/Cargo.toml", "")

        let drafts = find(fx)
        #expect(Set(drafts.keys) == [fx.path("app")])
        #expect(candidatePaths(drafts[fx.path("app")]) == [fx.path("app/node_modules")])
    }

    @Test func hiddenFoldersOutsideProjectsAreSkipped() {
        let fx = Fixture()
        fx.write(".hidden/proj/package.json", "{}")
        fx.file(".hidden/proj/node_modules/a/index.js")
        fx.write("visible/package.json", "{}")

        let drafts = find(fx)
        #expect(Set(drafts.keys) == [fx.path("visible")])
    }

    @Test func gitFileWorktreeBecomesProject() {
        let fx = Fixture()
        fx.write("wt/.git", "gitdir: /x/.git/worktrees/y\n")
        fx.write("wt/package.json", "{}")
        fx.file("wt/node_modules/a/index.js")

        let draft = find(fx)[fx.path("wt")]
        #expect(draft?.isWorktree == true)
        #expect(draft?.isGitRoot == true)
        #expect(ProjectFinder.gitFileKind(fx.path("wt")) == .worktree)
    }

    @Test func submoduleStaysInParentProject() {
        let fx = Fixture()
        fx.dir("parent/.git")
        fx.write("parent/package.json", "{}")
        fx.write("parent/sub/.git", "gitdir: ../.git/modules/sub\n")
        fx.write("parent/sub/package.json", "{}")
        fx.file("parent/sub/node_modules/a/index.js")

        let drafts = find(fx)
        #expect(Set(drafts.keys) == [fx.path("parent")])
        #expect(candidatePaths(drafts[fx.path("parent")]) == [fx.path("parent/sub/node_modules")])
        #expect(ProjectFinder.gitFileKind(fx.path("parent/sub")) == .submodule)
    }

    @Test func genericDistKeptOnlyWhenGitIgnored() {
        guard Git.available else { return }
        let fx = Fixture()
        let repo = fx.dir("site")
        Git.initRepo(repo)
        fx.write("site/.gitignore", "dist/\n")
        fx.write("site/package.json", "{}")
        fx.file("site/dist/main.js")
        fx.file("site/build/main.js")

        let drafts = Array(find(fx).values)
        #expect(candidatePaths(drafts.first) == [fx.path("site/dist"), fx.path("site/build")])

        let filtered = Scanner.applyGitIgnore(drafts)
        #expect(candidatePaths(filtered.first) == [fx.path("site/dist")])
        #expect(filtered.first?.candidates.first?.rule.id == "node-dist")
    }

    @Test func nonGitProjectDropsGenericFolders() {
        let fx = Fixture()
        fx.write("app/package.json", "{}")
        fx.file("app/dist/main.js")
        fx.file("app/node_modules/a/index.js")

        let filtered = Scanner.applyGitIgnore(Array(find(fx).values))
        #expect(candidatePaths(filtered.first) == [fx.path("app/node_modules")])
    }

    @Test func excludedPathsAreHonored() {
        let fx = Fixture()
        fx.write("keep/package.json", "{}")
        fx.write("skip/package.json", "{}")
        fx.write("mixed/package.json", "{}")
        fx.file("mixed/node_modules/a/index.js")

        let drafts = find(fx, excluded: [fx.path("skip"), fx.path("mixed/node_modules")])
        #expect(Set(drafts.keys) == [fx.path("keep"), fx.path("mixed")])
        #expect(candidatePaths(drafts[fx.path("mixed")]).isEmpty)
        #expect(find(fx, excluded: [fx.root]).isEmpty)
    }

    @Test func appBundlesAreSkipped() {
        let fx = Fixture()
        fx.write("Tool.app/Contents/package.json", "{}")
        fx.file("Tool.app/Contents/node_modules/a/index.js")
        fx.write("Tool.app/package.json", "{}")
        fx.file("Tool.app/node_modules/a/index.js")

        #expect(find(fx).isEmpty)
    }

    @Test func targetWithoutCargoIsIgnored() {
        let fx = Fixture()
        fx.write("web/package.json", "{}")
        fx.file("web/target/out.bin")
        fx.write("crate/Cargo.toml", "")
        fx.file("crate/target/debug/out.bin")

        let drafts = find(fx)
        #expect(candidatePaths(drafts[fx.path("web")]).isEmpty)
        #expect(candidatePaths(drafts[fx.path("crate")]) == [fx.path("crate/target")])
        #expect(drafts[fx.path("crate")]?.candidates.first?.rule.id == "rust-target")
    }
}

@Suite struct RulesTests {
    @Test func wildcardMarkers() {
        #expect(Rules.markerPresent("*.csproj", in: ["App.csproj", "Program.cs"]))
        #expect(!Rules.markerPresent("*.csproj", in: ["Program.cs", "csproj"]))
        #expect(Rules.markerPresent("package.json", in: ["package.json"]))
        #expect(!Rules.markerPresent("package.json", in: ["package.json5"]))
        #expect(ProjectFinder.rule(for: "bin", siblings: ["Api.csproj"])?.id == "dotnet-bin")
        #expect(ProjectFinder.rule(for: "bin", siblings: ["README.md"]) == nil)
    }

    @Test func ruleChosenBySiblings() {
        #expect(ProjectFinder.rule(for: "build", siblings: ["build.gradle"])?.id == "gradle-build")
        #expect(ProjectFinder.rule(for: "build", siblings: ["package.json"])?.id == "node-build")
        #expect(ProjectFinder.rule(for: "build", siblings: ["pubspec.yaml"])?.id == "flutter-build")
        #expect(ProjectFinder.rule(for: "target", siblings: ["Cargo.toml"])?.id == "rust-target")
        #expect(ProjectFinder.rule(for: "target", siblings: ["pom.xml"])?.id == "maven-target")
        #expect(ProjectFinder.rule(for: "target", siblings: []) == nil)
        #expect(ProjectFinder.rule(for: "node_modules", siblings: [])?.id == "node-modules")
        #expect(ProjectFinder.rule(for: "src", siblings: ["package.json"]) == nil)
    }

    @Test func ruleIDsAreUnique() {
        let ids = Rules.artifacts.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func noRuleTargetsProtectedNames() {
        let protected: Set<String> = [
            ".git", ".hg", ".svn", "src", "lib", "app", ".env", ".ssh", "Documents", "Desktop", "Downloads",
            "Library", "Applications", "Pictures", "Music", "Movies", ".github", "test", "tests", "docs",
        ]
        for rule in Rules.artifacts {
            #expect(!protected.contains(rule.directory), "\(rule.id) targets \(rule.directory)")
            #expect(!rule.directory.isEmpty && !rule.directory.contains("/"))
        }
    }

    @Test func ecosystemsFromMarkers() {
        #expect(Rules.ecosystems(in: ["package.json", "Cargo.toml"]) == [.node, .rust])
        #expect(Rules.ecosystems(in: ["App.xcodeproj"]) == [.apple])
        #expect(Rules.ecosystems(in: ["README.md"]).isEmpty)
    }
}
