import Foundation
import Testing
@testable import SweepCore

struct JournalTests {
    @Test func changeSetMatchesOnlyPathsInside() {
        let changes = ChangeJournal.ChangeSet(["/a/app/node_modules/pkg", "/a/other", "/a/app-two/src"])
        #expect(changes.touches("/a/app/node_modules"))
        #expect(changes.touches("/a/other"))
        #expect(!changes.touches("/a/app"+"/dist"))
        #expect(!changes.touches("/a/app-tw"))
        #expect(!changes.touches("/a/app/node"))
        #expect(ChangeJournal.ChangeSet([]).touches("/a") == false)
    }

    @Test func missingOrStaleMarkMeansFullScan() {
        #expect(ChangeJournal.changes(since: nil, under: [NSTemporaryDirectory()]) == nil)
        guard let mark = ChangeJournal.currentMark() else { return }
        let old = ChangeJournal.Mark(eventID: mark.eventID, volume: mark.volume, date: Date(timeIntervalSinceNow: -30 * 24 * 3600))
        #expect(ChangeJournal.changes(since: old, under: [NSTemporaryDirectory()]) == nil)
        let otherVolume = ChangeJournal.Mark(eventID: mark.eventID, volume: "not-a-volume", date: Date())
        #expect(ChangeJournal.changes(since: otherVolume, under: [NSTemporaryDirectory()]) == nil)
    }

    @Test func rescanMeasuresOnlyChangedFolders() async throws {
        let fx = Fixture()
        for name in ["one", "two"] {
            fx.write("\(name)/package.json", "{}")
            fx.write("\(name)/package-lock.json", "{}")
            fx.file("\(name)/node_modules/pkg/index.js", bytes: 8_192)
        }
        let settings = SweepSettings(roots: [fx.root])
        let scanner = Scanner(settings: settings)
        try await Task.sleep(for: .milliseconds(1500))

        let mark = ChangeJournal.currentMark(for: fx.root)
        let (first, firstMeasured) = await scanner.scanProjects(reuse: nil, progress: nil)
        #expect(firstMeasured == 2)
        var previous = ScanResult(roots: settings.roots, projects: first)
        previous.journal = mark

        fx.file("one/node_modules/pkg/big.bin", bytes: 400_000)
        try await Task.sleep(for: .milliseconds(1500))

        guard let reuse = SizeReuse(previous: previous, settings: settings) else {
            Issue.record("FSEvents history should be readable for the temp folder")
            return
        }
        let (second, secondMeasured) = await scanner.scanProjects(reuse: reuse, progress: nil)
        #expect(secondMeasured == 1)

        let before = first.first { $0.name == "one" }?.reclaimable ?? 0
        let after = second.first { $0.name == "one" }?.reclaimable ?? 0
        #expect(after > before + 300_000)
        #expect(second.first { $0.name == "two" }?.reclaimable == first.first { $0.name == "two" }?.reclaimable)
    }

    @Test func deletedFolderIsNotReused() async throws {
        let fx = Fixture()
        fx.write("app/package.json", "{}")
        fx.file("app/node_modules/pkg/index.js", bytes: 8_192)
        fx.file("app/.next/cache/a", bytes: 8_192)
        let settings = SweepSettings(roots: [fx.root])
        let scanner = Scanner(settings: settings)

        let mark = ChangeJournal.currentMark(for: fx.root)
        let (first, _) = await scanner.scanProjects(reuse: nil, progress: nil)
        var previous = ScanResult(roots: settings.roots, projects: first)
        previous.journal = mark

        try FileManager.default.removeItem(atPath: fx.path("app/.next"))
        try await Task.sleep(for: .milliseconds(1500))

        let reuse = SizeReuse(previous: previous, settings: settings)
        let (second, _) = await scanner.scanProjects(reuse: reuse, progress: nil)
        #expect(second.first?.artifacts.contains { $0.folderName == ".next" } == false)
    }
}
