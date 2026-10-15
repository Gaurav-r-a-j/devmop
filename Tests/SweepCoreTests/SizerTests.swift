import Darwin
import Foundation
import Testing
@testable import SweepCore

@Suite struct SizerTests {
    @Test func allocatedMatchesLstatBlocks() {
        let fx = Fixture()
        fx.file("a/one.bin", bytes: 10_000)
        fx.file("a/b/two.bin", bytes: 70_000)
        fx.file("a/b/c/three.bin", bytes: 5)
        fx.file("a/top.txt", bytes: 300_000)

        let info = DirectorySizer.size(of: fx.path("a"))
        #expect(info.allocated == expectedAllocated(fx.path("a")))
        #expect(info.allocated > 0)
        #expect(info.fileCount == 4)
        #expect(info.reclaimable == info.allocated)
        #expect(info.unreadableCount == 0)
    }

    @Test func hardlinksInsideCountOnceAndAreReclaimable() {
        let fx = Fixture()
        let original = fx.file("a/original.bin", bytes: 200_000)
        fx.dir("a/sub")
        #expect(link(original, fx.path("a/sub/copy.bin")) == 0)

        var st = stat()
        lstat(original, &st)
        let fileBytes = Int64(st.st_blocks) * 512

        let info = DirectorySizer.size(of: fx.path("a"))
        #expect(info.allocated == fileBytes)
        #expect(info.reclaimable == fileBytes)
        #expect(info.fileCount == 2)
    }

    @Test func hardlinkOutsideIsNotReclaimable() {
        let fx = Fixture()
        let inside = fx.file("a/shared.bin", bytes: 200_000)
        let other = fx.file("a/own.bin", bytes: 1_000)
        #expect(link(inside, fx.path("outside.bin")) == 0)

        var st = stat()
        lstat(inside, &st)
        let sharedBytes = Int64(st.st_blocks) * 512
        lstat(other, &st)
        let ownBytes = Int64(st.st_blocks) * 512

        let info = DirectorySizer.size(of: fx.path("a"))
        #expect(info.allocated == sharedBytes + ownBytes)
        #expect(info.reclaimable == ownBytes)
    }

    @Test func apfsCloneIsMostlyNotReclaimable() {
        let fx = Fixture()
        let source = fx.file("source.bin", bytes: 4_000_000)
        fx.dir("a")
        guard clonefile(source, fx.path("a/clone.bin"), 0) == 0 else { return }

        let info = DirectorySizer.size(of: fx.path("a"))
        #expect(info.allocated >= 4_000_000)
        #expect(info.reclaimable < info.allocated / 4)
    }

    @Test func symlinksAreNotFollowed() throws {
        let fx = Fixture()
        fx.file("big/blob.bin", bytes: 2_000_000)
        fx.file("a/small.bin", bytes: 100)
        try FileManager.default.createSymbolicLink(atPath: fx.path("a/link"), withDestinationPath: fx.path("big"))
        try FileManager.default.createSymbolicLink(atPath: fx.path("a/file-link"), withDestinationPath: fx.path("big/blob.bin"))

        let info = DirectorySizer.size(of: fx.path("a"))
        #expect(info.allocated < 100_000)
        #expect(info.allocated == expectedAllocated(fx.path("a")))
    }

    @Test(.timeLimit(.minutes(1))) func symlinkLoopTerminates() throws {
        let fx = Fixture()
        fx.file("a/x/data.bin", bytes: 1_000)
        try FileManager.default.createSymbolicLink(atPath: fx.path("a/x/up"), withDestinationPath: fx.path("a"))
        try FileManager.default.createSymbolicLink(atPath: fx.path("a/p"), withDestinationPath: fx.path("a/q"))
        try FileManager.default.createSymbolicLink(atPath: fx.path("a/q"), withDestinationPath: fx.path("a/p"))

        let info = DirectorySizer.size(of: fx.path("a"))
        #expect(info.allocated == expectedAllocated(fx.path("a")))
    }

    @Test func unreadableFolderIsCounted() {
        guard getuid() != 0 else { return }
        let fx = Fixture()
        fx.file("a/ok.bin", bytes: 1_000)
        fx.file("a/locked/hidden.bin", bytes: 1_000)
        chmod(fx.path("a/locked"), 0)
        defer { chmod(fx.path("a/locked"), 0o755) }

        let info = DirectorySizer.size(of: fx.path("a"))
        #expect(info.unreadableCount >= 1)
        #expect(info.fileCount == 1)
    }

    @Test func parallelFanOutMatchesSerialTotals() {
        let fx = Fixture()
        for index in 0..<240 {
            fx.file("a/pkg\(index)/index.js", bytes: 100 + index * 37)
            fx.file("a/pkg\(index)/lib/deep/file.js", bytes: 5_000 + index)
        }
        let original = fx.file("a/pkg0/shared.bin", bytes: 50_000)
        #expect(link(original, fx.path("a/pkg239/shared-link.bin")) == 0)

        let info = DirectorySizer.size(of: fx.path("a"))
        #expect(info.allocated == expectedAllocated(fx.path("a")))
        #expect(info.reclaimable == info.allocated)
        #expect(info.fileCount == 240 * 2 + 2)
    }

    @Test func singleFileAndMissingPath() {
        let fx = Fixture()
        let file = fx.file("one.bin", bytes: 10_000)
        var st = stat()
        lstat(file, &st)
        #expect(DirectorySizer.size(of: file).allocated == Int64(st.st_blocks) * 512)
        #expect(DirectorySizer.size(of: fx.path("missing")) == .zero)
    }

    @Test func sizesKeyedByPath() async {
        let fx = Fixture()
        let a = fx.dir("a")
        let b = fx.dir("b")
        fx.file("a/f", bytes: 9_000)
        fx.file("b/f", bytes: 90_000)
        let sizes = await DirectorySizer.sizes(of: [a, b])
        #expect(sizes[a]?.allocated == expectedAllocated(a))
        #expect(sizes[b]?.allocated == expectedAllocated(b))
    }
}
