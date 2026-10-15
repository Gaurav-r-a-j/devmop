import AppKit
import Foundation

/// Items behind macOS's "System Data": backups, installers, snapshots, logs and app caches.
enum SystemData {
    static let snapshotsID = "tm-snapshots"
    static let appCachesID = "app-caches"
    static let backupPrefix = "ios-backup:"
    static let installerPrefix = "macos-installer:"

    static func definitions(home: String, coveredCacheNames: Set<String>) -> [CacheItem] {
        let library = "\(home)/Library"
        var items = backups(home: home) + installers()

        items += [
            CacheItem(id: "ios-updates", name: "iPhone & iPad update files", group: .system, symbol: "arrow.down.app",
                      detail: "Software updates Finder downloaded to update a device. Downloaded again if needed.",
                      paths: ["iPhone", "iPad", "iPod"].map { "\(library)/iTunes/\($0) Software Updates" },
                      tier: .safe, method: .deleteContents),
            CacheItem(id: "user-logs", name: "Logs & crash reports", group: .system, symbol: "doc.text",
                      detail: "Diagnostic logs apps write over time. Nothing needs them to run.",
                      paths: ["\(library)/Logs"], tier: .safe, method: .deleteContents),
            CacheItem(id: "mail-downloads", name: "Mail attachment copies", group: .system, symbol: "paperclip",
                      detail: "Copies Mail makes when you open an attachment. The originals stay in your mail.",
                      paths: ["\(library)/Containers/com.apple.mail/Data/Library/Mail Downloads"],
                      tier: .safe, method: .deleteContents, quitApp: "Mail"),
        ]

        if SystemInfo.hasLocalSnapshots() {
            items.append(CacheItem(
                id: snapshotsID, name: "Time Machine local snapshots", group: .system, symbol: "clock.arrow.circlepath",
                detail: "Hourly restore points kept on this Mac. Backups on your Time Machine disk aren't affected.",
                paths: [], tier: .review,
                method: .command(tool: "tmutil", arguments: ["thinlocalsnapshots", "/", "999999999999", "4"]),
                size: SizeInfo(allocated: SystemInfo.purgeableBytes(), reclaimable: SystemInfo.purgeableBytes(), isEstimate: true)
            ))
        }

        if let icloud = ICloudDownloads.item(home: home) { items.append(icloud) }
        items += browserCaches(library: library)

        let covered = coveredCacheNames.union(browserFolderNames)
        let appCaches = appCacheFolders(in: "\(library)/Caches", excluding: covered)
        if !appCaches.isEmpty {
            items.append(CacheItem(
                id: appCachesID, name: "App caches", group: .system, symbol: "square.stack.3d.down.right",
                detail: "Cache folders of \(appCaches.count) apps that aren't running. Apps rebuild them as needed.",
                paths: appCaches, tier: .safe, method: .deleteContents
            ))
        }
        return items
    }

    // MARK: Device backups

    static func backups(home: String) -> [CacheItem] {
        let directory = "\(home)/Library/Application Support/MobileSync/Backup"
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }

        return folders.compactMap { folder -> CacheItem? in
            let path = "\(directory)/\(folder)"
            guard let data = FileManager.default.contents(atPath: "\(path)/Info.plist"),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }

            let device = info["Device Name"] as? String ?? info["Display Name"] as? String ?? "Unknown device"
            let product = info["Product Name"] as? String
            let date = info["Last Backup Date"] as? Date
            let when = date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "an unknown date"
            return CacheItem(
                id: backupPrefix + folder, name: "Backup of \(device)", group: .system, symbol: "iphone.and.arrow.forward",
                detail: "\(product.map { "\($0) · " } ?? "")Last backed up \(when). Delete only if you have a newer backup or no longer need it.",
                paths: [path], tier: .review, method: .deletePaths
            )
        }
    }

    // MARK: macOS installers

    private static func installers() -> [CacheItem] {
        guard let apps = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") else { return [] }
        return apps.filter(isInstallerName).compactMap { name -> CacheItem? in
            let path = "/Applications/\(name)"
            guard isMacOSInstaller(path) else { return nil }
            return CacheItem(
                id: installerPrefix + name, name: (name as NSString).deletingPathExtension, group: .system, symbol: "macwindow.badge.plus",
                detail: "A leftover macOS installer. Download it again from the App Store if you need it.",
                paths: [path], tier: .rebuildable, method: .deletePaths
            )
        }
    }

    static func isInstallerName(_ name: String) -> Bool {
        name.hasPrefix("Install macOS ") && name.hasSuffix(".app")
    }

    /// A real macOS installer app in /Applications, not just something named like one.
    static func isMacOSInstaller(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard (standardized as NSString).deletingLastPathComponent == "/Applications",
              isInstallerName((standardized as NSString).lastPathComponent),
              let bundle = Bundle(path: standardized),
              let identifier = bundle.bundleIdentifier
        else { return false }
        return identifier.hasPrefix("com.apple.InstallAssistant")
    }

    // MARK: Browsers

    private static let browsers: [(id: String, name: String, folder: String, process: String)] = [
        ("chrome", "Google Chrome", "Google/Chrome", "Google Chrome"),
        ("arc", "Arc", "company.thebrowser.Browser", "Arc"),
        ("brave", "Brave", "BraveSoftware/Brave-Browser", "Brave Browser"),
        ("edge", "Microsoft Edge", "Microsoft Edge", "Microsoft Edge"),
        ("firefox", "Firefox", "Firefox", "firefox"),
        ("safari", "Safari", "com.apple.Safari", "Safari"),
        ("opera", "Opera", "com.operasoftware.Opera", "Opera"),
    ]

    private static var browserFolderNames: Set<String> {
        Set(browsers.map { String($0.folder.split(separator: "/")[0]) })
    }

    private static func browserCaches(library: String) -> [CacheItem] {
        browsers.map { browser in
            CacheItem(id: "browser-\(browser.id)", name: "\(browser.name) cache", group: .browsers, symbol: "globe",
                      detail: "Saved copies of web pages and images. History, passwords and logins aren't touched.",
                      paths: ["\(library)/Caches/\(browser.folder)"], tier: .safe, method: .deleteContents,
                      quitApp: browser.process)
        }
    }

    // MARK: App caches

    /// Cache folders of apps that aren't running, skipping Apple's own and anything another item already covers.
    static func appCacheFolders(in caches: String, excluding covered: Set<String>) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: caches) else { return [] }
        let running = runningBundleIdentifiers()
        return names.compactMap { name -> String? in
            guard !name.hasPrefix("."), !name.hasPrefix("com.apple."), !covered.contains(name) else { return nil }
            let lowered = name.lowercased()
            if running.contains(where: { lowered == $0 || lowered.hasPrefix($0 + ".") }) { return nil }
            let path = "\(caches)/\(name)"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard attributes?[.type] as? FileAttributeType == .typeDirectory else { return nil }
            return path
        }
        .sorted()
    }

    static func runningBundleIdentifiers() -> Set<String> {
        let identifiers = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        let names = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName?.lowercased() }
        return Set(identifiers + names)
    }
}
