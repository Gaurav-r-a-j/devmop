import Darwin
import Foundation
import Testing
@testable import SweepCore

struct RemovalTests {
    @Test func removerSkipsReadOnlyFoldersAndDeletesTheRest() {
        let fx = Fixture()
        fx.file("cache/a.bin", bytes: 200_000)
        fx.file("cache/b/c.bin", bytes: 200_000)
        fx.file("cache/locked/keep.bin", bytes: 50_000)
        chmod(fx.path("cache/locked"), 0o555)

        let before = DirectorySizer.size(of: fx.path("cache")).reclaimable
        let result = Remover.remove(fx.path("cache"))

        #expect(result.skipped >= 1)
        #expect(!fx.exists("cache/a.bin"))
        #expect(!fx.exists("cache/b"))
        #expect(fx.exists("cache/locked/keep.bin"))
        let after = DirectorySizer.size(of: fx.path("cache")).reclaimable
        #expect(result.freed == before - after)
        #expect(result.freed >= 400_000)
    }

    @Test func removerDeletesReadOnlyFilesInWritableFolders() {
        let fx = Fixture()
        let file = fx.file("cache/readonly.bin", bytes: 10_000)
        chmod(file, 0o444)
        let result = Remover.remove(fx.path("cache"))
        #expect(result.skipped == 0)
        #expect(!fx.exists("cache"))
    }

    @Test func removerNeverFollowsLinks() throws {
        let fx = Fixture()
        fx.file("outside/precious.txt", bytes: 1_000)
        fx.dir("cache")
        try FileManager.default.createSymbolicLink(atPath: fx.path("cache/link"), withDestinationPath: fx.path("outside"))
        _ = Remover.remove(fx.path("cache"))
        #expect(fx.exists("outside/precious.txt"))
        #expect(!fx.exists("cache"))
    }

    @Test func dockerReclaimedSpaceIsParsed() {
        #expect(DockerInspector.reclaimed(in: "Deleted Images:\nabc\n\nTotal reclaimed space: 1.2GB") == 1_200_000_000)
        #expect(DockerInspector.reclaimed(in: "Total reclaimed space: 0B") == 0)
        #expect(DockerInspector.reclaimed(in: "nothing here") == nil)
    }

    @Test func trashIsReviewTierAndNeverTrashedAgain() {
        guard let trash = CacheCatalog.definitions().first(where: { $0.id == CacheCatalog.trashID }) else {
            Issue.record("Trash should be in the catalog")
            return
        }
        #expect(trash.tier == .review)
        #expect(trash.group == .trash)
        #expect(!CleanTarget.cache(trash).usesTrash(.trash))
    }

    @Test func oldHistoryWithoutNewFieldsStillLoads() throws {
        let json = #"{"targetID":"cache:npm","title":"npm cache","path":null,"bytes":42,"succeeded":true,"message":null,"rebuildHint":null,"trashedPaths":[]}"#
        let outcome = try JSONDecoder().decode(CleanOutcome.self, from: Data(json.utf8))
        #expect(outcome.bytes == 42)
        #expect(outcome.freedNow == 42)
        #expect(!outcome.isPartial)
    }
}
