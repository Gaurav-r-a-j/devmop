import Darwin
import Foundation
import Testing
@testable import SweepCore

struct UserFilesTests {
    private func randomData(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ Int(seed) &* 7) })
    }

    @Test func downloadsFindInstallersExtractedArchivesAndOldFiles() {
        let fx = Fixture()
        fx.write("Downloads/Tool.dmg", data: randomData(2_000_000, seed: 1))
        fx.write("Downloads/photos.tar.gz", data: randomData(1_500_000, seed: 2))
        fx.dir("Downloads/photos")
        fx.write("Downloads/notes.zip", data: randomData(1_200_000, seed: 3))
        let old = fx.write("Downloads/old-report.pdf", data: randomData(1_100_000, seed: 4))
        let longAgo = Date().addingTimeInterval(-200 * 24 * 3600).timeIntervalSince1970
        var times = [timeval(tv_sec: Int(longAgo), tv_usec: 0), timeval(tv_sec: Int(longAgo), tv_usec: 0)]
        utimes(old, &times)

        let files = UserFiles.scan(home: fx.root)
        func reasons(_ name: String) -> [UserFileReason] { files.first { $0.name == name }?.reasons ?? [] }

        #expect(reasons("Tool.dmg").contains(.installer))
        #expect(reasons("photos.tar.gz").contains(.extractedArchive))
        #expect(!reasons("notes.zip").contains(.extractedArchive))
        #expect(reasons("old-report.pdf").contains(.oldDownload))
    }

    @Test func duplicatesNeedIdenticalContentNotJustSize() throws {
        let fx = Fixture()
        let content = randomData(2_000_000, seed: 9)
        fx.write("Documents/a/video.mov", data: content)
        fx.write("Documents/b/video copy.mov", data: content)
        var different = content
        different[1_000_000] ^= 0xFF
        fx.write("Documents/c/similar.mov", data: different)
        let linked = fx.write("Documents/d/original.bin", data: randomData(1_300_000, seed: 11))
        try FileManager.default.linkItem(atPath: linked, toPath: fx.path("Documents/d/hardlink.bin"))

        let duplicates = UserFiles.scan(home: fx.root).filter { $0.reasons.contains(.duplicate) }
        #expect(Set(duplicates.map(\.name)) == ["video.mov", "video copy.mov"])
        #expect(duplicates.allSatisfy { $0.otherCopies?.count == 1 })
        #expect(Set(duplicates.compactMap(\.contentHash)).count == 1)
    }

    @Test func buildFoldersHiddenFilesAndBundlesAreSkipped() {
        let fx = Fixture()
        let content = randomData(1_500_000, seed: 5)
        fx.write("Documents/app/node_modules/pkg/big.bin", data: content)
        fx.write("Documents/.hidden/big.bin", data: content)
        fx.write("Documents/Thing.app/Contents/big.bin", data: content)
        fx.write("Documents/keep/big.bin", data: content)
        let paths = UserFiles.scan(home: fx.root).map(\.path)
        #expect(!paths.contains { $0.contains("node_modules") || $0.contains(".hidden") || $0.contains("Thing.app") })
    }

    @Test func archiveBaseNameStripsEveryArchiveExtension() {
        #expect(UserFiles.archiveBaseName("photos.tar.gz") == "photos")
        #expect(UserFiles.archiveBaseName("site.zip") == "site")
        #expect(UserFiles.archiveBaseName("report.pdf") == "report.pdf")
    }

    @Test func lastCopyOfADuplicateIsAlwaysKept() {
        let fx = Fixture()
        let content = randomData(1_200_000, seed: 7)
        let a = fx.write("Documents/a.bin", data: content)
        let b = fx.write("Documents/b.bin", data: content)
        let hash = UserFiles.fullHash(a)
        func file(_ path: String, other: String) -> UserFile {
            UserFile(path: path, name: (path as NSString).lastPathComponent, allocated: 0, reclaimable: 0,
                     modified: nil, lastOpened: nil, reasons: [.duplicate], contentHash: hash, otherCopies: [other])
        }

        #expect(Cleaner.duplicateProblem(file(b, other: a), batchFiles: [b]) == nil)
        let both: Set<String> = [a, b]
        let results = [Cleaner.duplicateProblem(file(a, other: b), batchFiles: both),
                       Cleaner.duplicateProblem(file(b, other: a), batchFiles: both)]
        #expect(results.filter { $0 == nil }.count == 1)

        try? Data("changed".utf8).write(to: URL(fileURLWithPath: a))
        #expect(Cleaner.duplicateProblem(file(b, other: a), batchFiles: [b]) != nil)
    }

    @Test func recheckRefusesChangedOpenAndOutsideFiles() throws {
        let fx = Fixture()
        let path = fx.write("Documents/movie.mov", data: randomData(1_000_000, seed: 3))
        var st = stat()
        lstat(path, &st)
        let file = UserFile(path: path, name: "movie.mov", allocated: Int64(st.st_blocks) * 512, reclaimable: 0,
                            modified: nil, lastOpened: nil, reasons: [.large])

        #expect(UserFiles.recheck(file, home: fx.root) == nil)
        #expect(UserFiles.recheck(file, home: fx.path("Elsewhere")) != nil)

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        #expect(UserFiles.recheck(file, home: fx.root) == "Open in an app")
        try handle.close()

        fx.write("Documents/movie.mov", data: randomData(3_000_000, seed: 4))
        #expect(UserFiles.recheck(file, home: fx.root) == "Changed since the scan")

        let library = fx.write("Library/secret.db", data: randomData(1_000_000, seed: 1))
        let libraryFile = UserFile(path: library, name: "secret.db", allocated: 0, reclaimable: 0, modified: nil, lastOpened: nil, reasons: [.large])
        #expect(UserFiles.recheck(libraryFile, home: fx.root) != nil)
    }

    @Test func userFilesAlwaysUseTrash() {
        let file = UserFile(path: "/x", name: "x", allocated: 0, reclaimable: 0, modified: nil, lastOpened: nil, reasons: [.large])
        #expect(CleanTarget.file(file).usesTrash(.permanent))
        #expect(CleanTarget.file(file).tier == .review)
    }
}
