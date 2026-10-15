import Foundation
import Testing
@testable import SweepCore

struct ExtrasTests {
    private func nvm(_ fx: Fixture, versions: [String], alias: String?) {
        for version in versions { fx.dir(".nvm/versions/node/\(version)/bin") }
        if let alias { fx.write(".nvm/alias/default", alias + "\n") }
    }

    @Test func nodeVersionsKeepDefaultAndNewest() {
        let fx = Fixture()
        nvm(fx, versions: ["v18.20.1", "v20.11.0", "v22.22.2"], alias: "20")
        let old = DeveloperExtras.oldNodeVersions(home: fx.root).map { ($0 as NSString).lastPathComponent }
        #expect(old == ["v18.20.1"])
    }

    @Test func unresolvableNodeAliasOffersNothing() {
        let fx = Fixture()
        nvm(fx, versions: ["v18.20.1", "v22.22.2"], alias: "lts/iron")
        #expect(DeveloperExtras.oldNodeVersions(home: fx.root).isEmpty)
        let missing = Fixture()
        nvm(missing, versions: ["v18.20.1", "v22.22.2"], alias: "16")
        #expect(DeveloperExtras.oldNodeVersions(home: missing.root).isEmpty)
    }

    @Test func singleNodeVersionIsNeverOffered() {
        let fx = Fixture()
        nvm(fx, versions: ["v22.22.2"], alias: nil)
        #expect(DeveloperExtras.oldNodeVersions(home: fx.root).isEmpty)
    }

    @Test func onlyExtensionsTheEditorMarkedObsoleteAreOffered() {
        let fx = Fixture()
        let directory = fx.dir(".vscode/extensions")
        fx.dir(".vscode/extensions/ms-python.python-2024.1.0")
        fx.dir(".vscode/extensions/ms-python.python-2024.2.0")
        fx.dir(".vscode/extensions/esbenp.prettier-vscode-10.0.0")
        fx.write(".vscode/extensions/.obsolete", #"{"ms-python.python-2024.1.0":true,"gone.ext-1.0.0":true,"../escape":true,"esbenp.prettier-vscode-10.0.0":false}"#)
        let obsolete = DeveloperExtras.obsoleteExtensions(in: directory).map { ($0 as NSString).lastPathComponent }
        #expect(obsolete == ["ms-python.python-2024.1.0"])
    }

    @Test func iCloudRecheckRefusesFilesOutsideICloudDrive() {
        let fx = Fixture()
        let file = fx.file("Documents/local.bin")
        #expect(ICloudDownloads.recheck(file, home: fx.root) == "Not in iCloud Drive")
        let inside = fx.file("Library/Mobile Documents/com~apple~CloudDocs/local.bin")
        #expect(ICloudDownloads.recheck(inside, home: fx.root) == "Not an iCloud file")
    }

    @Test func removingICloudDownloadsNeverUsesTrash() {
        let item = CacheItem(id: ICloudDownloads.id, name: "x", group: .system, symbol: "", detail: "", paths: ["/a"],
                             tier: .rebuildable, method: .evictDownloads)
        #expect(!CleanTarget.cache(item).usesTrash(.trash))
    }

    @Test func aiModelsAreReviewOnlyDeveloperItems() {
        let items = DeveloperExtras.definitions(home: Fixture().root).filter { $0.group == .aiModels }
        #expect(items.count == 4)
        #expect(items.allSatisfy { $0.tier == .review && $0.group.isDeveloper })
    }
}
