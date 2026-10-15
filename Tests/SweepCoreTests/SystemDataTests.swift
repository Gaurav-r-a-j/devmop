import Foundation
import Testing
@testable import SweepCore

struct SystemDataTests {
    @Test func appCachesSkipAppleCoveredAndLinkedFolders() throws {
        let fx = Fixture()
        let caches = fx.dir("Caches")
        fx.file("Caches/com.example.editor/blob", bytes: 1_000)
        fx.file("Caches/com.apple.Something/blob")
        fx.file("Caches/pnpm/blob")
        fx.dir("elsewhere")
        try FileManager.default.createSymbolicLink(atPath: fx.path("Caches/linked"), withDestinationPath: fx.path("elsewhere"))
        fx.file("Caches/loose-file.db")

        let folders = SystemData.appCacheFolders(in: caches, excluding: ["pnpm"])
        #expect(folders == [fx.path("Caches/com.example.editor")])
    }

    @Test func backupsAreReadFromInfoPlist() throws {
        let fx = Fixture()
        let backup = fx.dir("Library/Application Support/MobileSync/Backup/00008110-ABC")
        let info: [String: Any] = ["Device Name": "Test iPhone", "Product Name": "iPhone 15", "Last Backup Date": Date(timeIntervalSince1970: 1_700_000_000)]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: backup + "/Info.plist"))
        fx.dir("Library/Application Support/MobileSync/Backup/not-a-backup")

        let items = SystemData.backups(home: fx.root)
        #expect(items.count == 1)
        #expect(items.first?.name == "Backup of Test iPhone")
        #expect(items.first?.tier == .review)
        #expect(items.first?.paths == [backup])
        #expect(items.first?.id == "ios-backup:00008110-ABC")
    }

    @Test func installerCheckNeedsRealAppleInstallerInApplications() {
        #expect(SystemData.isInstallerName("Install macOS Sonoma.app"))
        #expect(!SystemData.isInstallerName("Install Something Else.app"))
        #expect(!SystemData.isMacOSInstaller("/Applications/Install macOS Fake.app"))
        #expect(!SystemData.isMacOSInstaller("/tmp/Install macOS Sonoma.app"))
        #expect(!SystemData.isMacOSInstaller("/Applications/../tmp/Install macOS Sonoma.app"))
    }

    @Test func systemItemsAreNeverInDeveloperGroups() {
        let fx = Fixture()
        let items = SystemData.definitions(home: fx.root, coveredCacheNames: [])
        #expect(items.allSatisfy { $0.group == .system || $0.group == .browsers })
        #expect(items.contains { $0.id == "browser-chrome" && $0.quitApp == "Google Chrome" })
        #expect(items.allSatisfy { !$0.group.isDeveloper })
    }

    @Test func developerCacheFoldersAreNotCountedTwice() {
        let all = CacheCatalog.definitions()
        let appCaches = all.first { $0.id == SystemData.appCachesID }?.paths ?? []
        let developerPaths = Set(all.filter { $0.group.isDeveloper }.flatMap(\.paths))
        #expect(appCaches.allSatisfy { !developerPaths.contains($0) })
        let browserPaths = all.filter { $0.group == .browsers }.flatMap(\.paths)
        #expect(appCaches.allSatisfy { path in !browserPaths.contains { $0.isInside(path) || path.isInside($0) } })
    }

    @Test func purgeableEstimateIsNeverNegative() {
        #expect(SystemInfo.purgeableBytes() >= 0)
    }
}
