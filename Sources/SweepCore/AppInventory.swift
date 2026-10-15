import AppKit
import CoreServices
import Foundation

public struct AppLeftover: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: String
    public var size: SizeInfo

    public init(path: String, kind: String, size: SizeInfo) {
        self.path = path
        self.kind = kind
        self.size = size
    }
}

public struct InstalledApp: Identifiable, Codable, Hashable, Sendable {
    /// The app's location, since two copies of one app share a bundle ID.
    public var id: String { path }
    public let bundleID: String
    public let name: String
    public let path: String
    public let version: String?
    public let isAppStore: Bool
    public var size: SizeInfo
    public var lastUsed: Date?
    public var leftovers: [AppLeftover]
    public var blockedReason: String?
    /// Set when the app installed parts outside your home folder that only its own uninstaller removes.
    public var systemPartsWarning: String?

    public var totalReclaimable: Int64 { size.reclaimable + leftovers.reduce(0) { $0 + $1.size.reclaimable } }
    /// Caches, settings, logs and window state: removed with the app.
    public var supportLeftovers: [AppLeftover] { leftovers.filter { !$0.mayHoldUserData } }
    /// App data and containers, which can hold documents; removed only when chosen separately.
    public var dataLeftovers: [AppLeftover] { leftovers.filter(\.mayHoldUserData) }
    public var uninstallBytes: Int64 { size.reclaimable + supportLeftovers.reduce(0) { $0 + $1.size.reclaimable } }
    public var dataBytes: Int64 { dataLeftovers.reduce(0) { $0 + $1.size.reclaimable } }
}

extension AppLeftover {
    static let dataKinds: Set<String> = ["App data", "Sandbox container", "Shared container"]
    public var mayHoldUserData: Bool { Self.dataKinds.contains(kind) }
}

/// Library data for an app that is no longer installed.
public struct OrphanedAppData: Identifiable, Codable, Hashable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public var leftovers: [AppLeftover]

    public var name: String { bundleID.split(separator: ".").last.map(String.init) ?? bundleID }
    public var reclaimable: Int64 { leftovers.reduce(0) { $0 + $1.size.reclaimable } }
}

public enum AppInventory {
    static let leftoverLocations: [(folder: String, kind: String, matchesName: Bool)] = [
        ("Application Support", "App data", true),
        ("Caches", "Cache", true),
        ("Containers", "Sandbox container", false),
        ("Group Containers", "Shared container", false),
        ("Preferences", "Settings", false),
        ("Preferences/ByHost", "Settings", false),
        ("Saved Application State", "Window state", false),
        ("HTTPStorages", "Web storage", false),
        ("WebKit", "Web data", false),
        ("Logs", "Logs", true),
        ("LaunchAgents", "Login item", false),
        ("Application Scripts", "Scripts", false),
    ]

    public static func appFolders(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", "\(home)/Applications"]
    }

    public static func scan(home: String = NSHomeDirectory()) async -> (apps: [InstalledApp], orphans: [OrphanedAppData]) {
        await scan(home: home, reuse: nil)
    }

    static func scan(home: String = NSHomeDirectory(), reuse: SizeReuse?) async -> (apps: [InstalledApp], orphans: [OrphanedAppData]) {
        let bundles = findBundles(home: home)
        let running = SystemData.runningBundleIdentifiers()
        let installedIDs = Set(bundles.map { $0.bundleID.lowercased() })
        let library = "\(home)/Library"

        var apps = bundles.map { bundle -> InstalledApp in
            var app = InstalledApp(
                bundleID: bundle.bundleID, name: bundle.name, path: bundle.path, version: bundle.version,
                isAppStore: FileManager.default.fileExists(atPath: bundle.path + "/Contents/_MASReceipt/receipt"),
                size: .zero, lastUsed: lastUsed(bundle.path),
                leftovers: leftovers(bundleID: bundle.bundleID, name: bundle.name, library: library)
            )
            if running.contains(bundle.bundleID.lowercased()) { app.blockedReason = "Quit \(bundle.name) first" }
            if bundles.contains(where: { $0.bundleID == bundle.bundleID && $0.path != bundle.path }) {
                app.leftovers = []
                app.systemPartsWarning = "Another copy of this app is installed, so its settings and data are kept."
            }
            app.systemPartsWarning = systemParts(bundleID: bundle.bundleID)
            return app
        }
        let orphans = orphanedData(library: library, installedIDs: installedIDs)

        let paths = apps.map(\.path) + apps.flatMap { $0.leftovers.map(\.path) } + orphans.flatMap { $0.leftovers.map(\.path) }
        var sizes: [String: SizeInfo] = [:]
        var toMeasure: [String] = []
        for path in paths {
            if let cached = reuse?.cached(path) { sizes[path] = cached } else { toMeasure.append(path) }
        }
        sizes.merge(await DirectorySizer.sizes(of: toMeasure)) { _, new in new }
        for index in apps.indices {
            apps[index].size = sizes[apps[index].path] ?? .zero
            for leftover in apps[index].leftovers.indices {
                apps[index].leftovers[leftover].size = sizes[apps[index].leftovers[leftover].path] ?? .zero
            }
        }
        let sizedOrphans = orphans.map { orphan -> OrphanedAppData in
            var orphan = orphan
            for index in orphan.leftovers.indices {
                orphan.leftovers[index].size = sizes[orphan.leftovers[index].path] ?? .zero
            }
            return orphan
        }
        .filter { $0.reclaimable > 0 }

        return (apps.sorted { $0.totalReclaimable > $1.totalReclaimable }, sizedOrphans.sorted { $0.reclaimable > $1.reclaimable })
    }

    // MARK: Finding apps

    struct Bundle: Hashable {
        let bundleID: String
        let name: String
        let path: String
        let version: String?
    }

    static func findBundles(home: String) -> [Bundle] {
        var result: [Bundle] = []
        let ownID = Foundation.Bundle.main.bundleIdentifier
        for folder in appFolders(home: home) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names {
                let path = "\(folder)/\(name)"
                if name.hasSuffix(".app") {
                    if let bundle = bundle(at: path), bundle.bundleID != ownID { result.append(bundle) }
                } else if !name.hasPrefix("."), let inner = try? FileManager.default.contentsOfDirectory(atPath: path) {
                    for innerName in inner where innerName.hasSuffix(".app") {
                        if let bundle = bundle(at: "\(path)/\(innerName)"), bundle.bundleID != ownID { result.append(bundle) }
                    }
                }
            }
        }
        return result
    }

    /// A third-party app bundle; Apple's own apps and installers are never returned.
    static func bundle(at path: String) -> Bundle? {
        guard let bundle = Foundation.Bundle(path: path), let identifier = bundle.bundleIdentifier,
              !identifier.lowercased().hasPrefix("com.apple."), !SystemData.isMacOSInstaller(path)
        else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return Bundle(bundleID: identifier, name: name, path: path, version: info["CFBundleShortVersionString"] as? String)
    }

    static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: Leftovers

    /// Library entries that belong to an app: exact bundle ID matches, plus exact app-name folders where apps use names.
    public static func leftovers(bundleID: String, name: String, library: String) -> [AppLeftover] {
        let id = bundleID.lowercased()
        let appName = name.lowercased()
        var found: [AppLeftover] = []
        for location in leftoverLocations {
            let directory = "\(library)/\(location.folder)"
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries {
                let lowered = entry.lowercased()
                let matchesID = lowered == id
                    || lowered == "\(id).plist"
                    || lowered == "\(id).savedstate"
                    || lowered == "\(id).binarycookies"
                    || (location.folder == "Preferences/ByHost" && lowered.hasPrefix("\(id)."))
                    || (location.folder == "LaunchAgents" && lowered.hasPrefix("\(id).") && lowered.hasSuffix(".plist"))
                    || (location.folder == "Group Containers" && lowered.hasSuffix(".\(id)"))
                let matchesName = location.matchesName && appName.count >= 3 && lowered == appName
                guard matchesID || matchesName else { continue }
                found.append(AppLeftover(path: "\(directory)/\(entry)", kind: location.kind, size: .zero))
            }
        }
        return found
    }

    /// Launch daemons or privileged helpers outside your home folder that DevSweep won't remove.
    static func systemParts(bundleID: String) -> String? {
        let id = bundleID.lowercased()
        let systemFolders = ["/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools"]
        let hasParts = systemFolders.contains { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains { $0.lowercased().hasPrefix(id) }
        }
        return hasParts ? "This app installed system parts. Use its own uninstaller if it has one to remove those too." : nil
    }

    /// Bundle-ID-named data in Containers, Application Support, Caches and Saved Application State with no installed app.
    static func orphanedData(library: String, installedIDs: Set<String>) -> [OrphanedAppData] {
        var byID: [String: [AppLeftover]] = [:]
        let locations: [(folder: String, kind: String, suffix: String)] = [
            ("Containers", "Sandbox container", ""),
            ("Application Support", "App data", ""),
            ("Caches", "Cache", ""),
            ("Saved Application State", "Window state", ".savedState"),
        ]
        for location in locations {
            let directory = "\(library)/\(location.folder)"
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries {
                var id = entry
                if !location.suffix.isEmpty {
                    guard entry.hasSuffix(location.suffix) else { continue }
                    id = String(entry.dropLast(location.suffix.count))
                }
                guard isOrphanCandidate(id, installedIDs: installedIDs) else { continue }
                byID[id.lowercased(), default: []].append(AppLeftover(path: "\(directory)/\(entry)", kind: location.kind, size: .zero))
            }
        }
        // Only sandboxed or windowed apps leave containers or saved state; command-line tools also use ID-style cache names.
        let appEvidence: Set<String> = ["Sandbox container", "Window state"]
        return byID
            .filter { $0.value.contains { appEvidence.contains($0.kind) } }
            .map { OrphanedAppData(bundleID: $0.key, leftovers: $0.value) }
    }

    /// A reverse-DNS name whose app isn't installed anywhere macOS knows about.
    static func isOrphanCandidate(_ id: String, installedIDs: Set<String>) -> Bool {
        let lowered = id.lowercased()
        let parts = lowered.split(separator: ".")
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }),
              ["com", "org", "net", "io", "app", "dev", "co", "us", "de", "uk", "me"].contains(String(parts[0])),
              !lowered.hasPrefix("com.apple."),
              lowered.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil
        else { return false }
        // Helpers and extensions of installed apps share the developer prefix (e.g. com.utmapp.*), so the whole prefix is skipped.
        let vendor = parts.prefix(2).joined(separator: ".") + "."
        if installedIDs.contains(where: { lowered == $0 || $0.hasPrefix(vendor) }) { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil
    }

    // MARK: Safety

    /// Re-checks an app right before it goes to the Trash.
    static func recheck(_ app: InstalledApp, home: String = NSHomeDirectory()) -> String? {
        let folder = (app.path as NSString).deletingLastPathComponent
        let allowed = appFolders(home: home)
        guard allowed.contains(folder) || allowed.contains((folder as NSString).deletingLastPathComponent) else {
            return "Not in an Applications folder"
        }
        guard let bundle = bundle(at: app.path), bundle.bundleID == app.bundleID else { return "The app changed since the scan" }
        if SystemData.runningBundleIdentifiers().contains(app.bundleID.lowercased()) { return "Quit \(app.name) first" }
        return nil
    }

    /// Leftovers found again right now; none when another copy of the app is still installed.
    static func currentLeftovers(for app: InstalledApp, home: String = NSHomeDirectory()) -> [AppLeftover] {
        let otherCopy = findBundles(home: home).contains { $0.bundleID == app.bundleID && $0.path != app.path }
        return otherCopy ? [] : leftovers(bundleID: app.bundleID, name: app.name, library: "\(home)/Library")
    }

    static func currentOrphanPaths(for orphan: OrphanedAppData, home: String = NSHomeDirectory()) -> [String] {
        let installed = Set(findBundles(home: home).map { $0.bundleID.lowercased() })
        guard isOrphanCandidate(orphan.bundleID, installedIDs: installed) else { return [] }
        let library = "\(home)/Library"
        let current = Set(orphanedData(library: library, installedIDs: installed)
            .first { $0.bundleID == orphan.bundleID }?.leftovers.map(\.path) ?? [])
        return orphan.leftovers.map(\.path).filter { current.contains($0) }
    }
}
