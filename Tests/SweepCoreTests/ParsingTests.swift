import Foundation
import Testing
@testable import SweepCore

@Suite struct ParsingTests {
    @Test func dockerSizes() {
        #expect(DockerInspector.parseSize("27.25GB (93%)") == 27_250_000_000)
        #expect(DockerInspector.parseSize("163.8kB") == 163_800)
        #expect(DockerInspector.parseSize("0B") == 0)
        #expect(DockerInspector.parseSize("1.2TB") == 1_200_000_000_000)
        #expect(DockerInspector.parseSize("512MB") == 512_000_000)
        #expect(DockerInspector.parseSize("12B") == 12)
        #expect(DockerInspector.parseSize("garbage") == 0)
        #expect(DockerInspector.parseSize("") == 0)
        #expect(DockerInspector.parseSize("xxGB") == 0)
    }

    @Test func simulatorRuntimeNames() {
        #expect(SimulatorInspector.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-26-3") == "iOS 26.3")
        #expect(SimulatorInspector.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-11-0") == "watchOS 11.0")
        #expect(SimulatorInspector.runtimeName("com.apple.CoreSimulator.SimRuntime.xrOS") == "xrOS")
    }

    @Test func orphanedWorkspaceStorage() {
        let fx = Fixture()
        let live = fx.dir("projects/Live Project")
        let storage = fx.dir("workspaceStorage")
        let encoded = URL(fileURLWithPath: live).absoluteString.removingSuffix("/")
        #expect(encoded.contains("%20"))

        fx.write("workspaceStorage/alive/workspace.json", #"{"folder":"\#(encoded)"}"#)
        fx.write("workspaceStorage/gone/workspace.json", #"{"folder":"file://\#(fx.path("projects/Deleted%20One"))"}"#)
        fx.write("workspaceStorage/gone-ws/workspace.json", #"{"workspace":"file://\#(fx.path("projects/missing.code-workspace"))"}"#)
        fx.write("workspaceStorage/remote/workspace.json", #"{"folder":"vscode-remote://ssh-remote+host/srv/app"}"#)
        fx.write("workspaceStorage/broken/workspace.json", "not json")
        fx.dir("workspaceStorage/empty")

        let orphans = Set(CacheCatalog.orphanedWorkspaceStorage(in: storage))
        #expect(orphans == [fx.path("workspaceStorage/gone"), fx.path("workspaceStorage/gone-ws")])
        #expect(CacheCatalog.orphanedWorkspaceStorage(in: fx.path("nope")).isEmpty)
    }
}

@Suite struct CleanTargetTests {
    private let project = sampleProject("/tmp/sweep-none/app")
    private let device = SimulatorDevice(udid: "UDID-1", name: "iPhone 17", runtime: "iOS 26.3", state: "Shutdown", isAvailable: true,
                                         path: "/tmp/sweep-none/dev", size: SizeInfo(allocated: 900, reclaimable: 800))
    private let runtime = SimulatorRuntime(id: "RT-1", name: "iOS 26.3", sizeBytes: 7_000, isDeletable: true, lastUsed: nil)

    private func cache(_ method: CleanMethod, fallback: CleanMethod? = nil, toolPath: String? = nil) -> CacheItem {
        CacheItem(id: "npm", name: "npm cache", group: .packageManagers, symbol: "shippingbox", detail: "", paths: ["/tmp/sweep-none/npm"],
                  tier: .safe, method: method, fallback: fallback, size: SizeInfo(allocated: 500, reclaimable: 400), toolPath: toolPath)
    }

    @Test func idsAndBytes() {
        let artifact = folderArtifact("/tmp/sweep-none/app/node_modules", size: SizeInfo(allocated: 300, reclaimable: 200))
        let targets: [(CleanTarget, String, Int64)] = [
            (.artifact(artifact, project: project), "artifact:/tmp/sweep-none/app/node_modules", 200),
            (.cache(cache(.deletePaths)), "cache:npm", 400),
            (.simulator(device), "simulator:UDID-1", 800),
            (.runtime(runtime), "runtime:RT-1", 7_000),
        ]
        for (target, id, bytes) in targets {
            #expect(target.id == id)
            #expect(target.bytes == bytes)
        }
    }

    @Test func tiers() {
        #expect(CleanTarget.simulator(device).tier == .rebuildable)
        #expect(CleanTarget.runtime(runtime).tier == .rebuildable)
        #expect(CleanTarget.cache(cache(.deletePaths)).tier == .safe)
        let worktree = Artifact(path: "/tmp/sweep-none/app", ruleID: "git-worktree", name: "Git worktree", tier: .review, kind: .worktree, rebuildHint: nil)
        #expect(CleanTarget.artifact(worktree, project: project).tier == .review)
    }

    @Test func blockedReasons() {
        let booted = SimulatorDevice(udid: "U", name: "n", runtime: "r", state: "Booted", isAvailable: true, path: "/tmp/sweep-none/x")
        #expect(CleanTarget.simulator(booted).blockedReason != nil)
        #expect(CleanTarget.simulator(device).blockedReason == nil)
        let system = SimulatorRuntime(id: "R", name: "n", sizeBytes: 1, isDeletable: false, lastUsed: nil)
        #expect(CleanTarget.runtime(system).blockedReason != nil)
    }

    @Test func usesTrash() {
        let folder = CleanTarget.artifact(folderArtifact("/tmp/sweep-none/app/node_modules"), project: project)
        let worktree = CleanTarget.artifact(Artifact(path: "/tmp/sweep-none/app", ruleID: "git-worktree", name: "Git worktree",
                                                     tier: .review, kind: .worktree, rebuildHint: nil), project: project)
        let command = CleanTarget.cache(cache(.command(tool: "npm", arguments: ["cache", "clean"]), fallback: .deleteContents, toolPath: "/usr/bin/true"))
        let commandFallback = CleanTarget.cache(cache(.command(tool: "npm", arguments: ["cache", "clean"]), fallback: .deleteContents))
        let paths = CleanTarget.cache(cache(.deletePaths))

        #expect(folder.usesTrash(.trash))
        #expect(worktree.usesTrash(.trash))
        #expect(worktree.usesTrash(.permanent))
        #expect(!command.usesTrash(.trash))
        #expect(commandFallback.usesTrash(.trash))
        #expect(paths.usesTrash(.trash))
        #expect(!CleanTarget.simulator(device).usesTrash(.trash))
        #expect(!CleanTarget.runtime(runtime).usesTrash(.trash))

        for target in [folder, command, commandFallback, paths, .simulator(device), .runtime(runtime)] {
            #expect(!target.usesTrash(.permanent))
        }
    }
}

private extension String {
    func removingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
