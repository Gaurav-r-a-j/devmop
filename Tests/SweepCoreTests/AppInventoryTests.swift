import Foundation
import Testing
@testable import SweepCore

struct AppInventoryTests {
    @Test func leftoversMatchExactIDsAndNamesOnly() {
        let fx = Fixture()
        let library = fx.dir("Library")
        fx.dir("Library/Application Support/Notion")
        fx.dir("Library/Application Support/Notion Calendar")
        fx.dir("Library/Caches/notion.id")
        fx.write("Library/Preferences/notion.id.plist", "x")
        fx.write("Library/Preferences/notion.id.helper.plist", "x")
        fx.dir("Library/Containers/notion.id")
        fx.dir("Library/Group Containers/ABCDE12345.notion.id")
        fx.dir("Library/Saved Application State/notion.id.savedState")
        fx.write("Library/LaunchAgents/notion.id.updater.plist", "x")
        fx.dir("Library/Caches/com.other.app")

        let found = AppInventory.leftovers(bundleID: "notion.id", name: "Notion", library: library)
        let names = Set(found.map { ($0.path as NSString).lastPathComponent })
        #expect(names == ["Notion", "notion.id", "notion.id.plist", "ABCDE12345.notion.id", "notion.id.savedState", "notion.id.updater.plist"])
        #expect(!names.contains("Notion Calendar"))
        #expect(!names.contains("notion.id.helper.plist"))
    }

    @Test func documentsInAppDataAreOptIn() {
        let app = InstalledApp(bundleID: "x.y.z", name: "Z", path: "/Applications/Z.app", version: nil, isAppStore: false,
                               size: SizeInfo(allocated: 100, reclaimable: 100), lastUsed: nil, leftovers: [
                                   AppLeftover(path: "/a", kind: "Cache", size: SizeInfo(allocated: 10, reclaimable: 10)),
                                   AppLeftover(path: "/b", kind: "App data", size: SizeInfo(allocated: 1_000, reclaimable: 1_000)),
                                   AppLeftover(path: "/c", kind: "Sandbox container", size: SizeInfo(allocated: 500, reclaimable: 500)),
                               ])
        #expect(app.uninstallBytes == 110)
        #expect(app.dataBytes == 1_500)
        #expect(app.supportLeftovers.map(\.path) == ["/a"])
    }

    @Test func orphansNeedAppEvidenceAndNoInstalledSibling() {
        let fx = Fixture()
        let library = fx.dir("Library")
        fx.dir("Library/Caches/org.swift.swiftpm")
        fx.dir("Library/Containers/com.deleted.thing")
        fx.dir("Library/Caches/com.deleted.thing")
        fx.dir("Library/Containers/com.vendor.helper")
        fx.dir("Library/Containers/com.apple.Notes")
        fx.dir("Library/Containers/not-reverse-dns")

        let orphans = AppInventory.orphanedData(library: library, installedIDs: ["com.vendor.mainapp"])
        #expect(orphans.map(\.bundleID) == ["com.deleted.thing"])
        #expect(orphans.first?.leftovers.count == 2)
    }

    @Test func leftoverDeletionIsLimitedToKnownLibraryFolders() throws {
        let fx = Fixture()
        let home = fx.root
        fx.dir("Library/Caches/com.x.y")
        fx.dir("Library/Mail/V10")
        fx.dir("elsewhere")
        try FileManager.default.createSymbolicLink(atPath: fx.path("Library/Caches/com.link.y"), withDestinationPath: fx.path("elsewhere"))

        #expect(Cleaner.unsafeLibraryItem(fx.path("Library/Caches/com.x.y"), home: home) == nil)
        #expect(Cleaner.unsafeLibraryItem(fx.path("Library/Mail/V10"), home: home) != nil)
        #expect(Cleaner.unsafeLibraryItem(fx.path("Library/Caches/com.link.y"), home: home) != nil)
        #expect(Cleaner.unsafeLibraryItem(fx.path("Library/Caches/../Mail"), home: home) != nil)
        #expect(Cleaner.unsafeLibraryItem(fx.path("Documents/thing"), home: home) != nil)
    }

    @Test func appleAppsAreNeverListed() {
        #expect(AppInventory.bundle(at: "/System/Applications/Calculator.app") == nil)
        #expect(AppInventory.bundle(at: "/Applications/Safari.app") == nil)
    }

    @Test func appTargetsAlwaysUseTrashAndAreReviewTier() {
        let app = InstalledApp(bundleID: "x.y.z", name: "Z", path: "/Applications/Z.app", version: nil, isAppStore: false,
                               size: .zero, lastUsed: nil, leftovers: [])
        for target in [CleanTarget.app(app), .appData(app)] {
            #expect(target.usesTrash(.permanent))
            #expect(target.tier == .review)
        }
    }
}
