import Foundation

/// Known global caches, each with the safest way to clean it.
public enum CacheCatalog {
    static func definitions(home: String = NSHomeDirectory()) -> [CacheItem] {
        let library = "\(home)/Library"
        let caches = "\(library)/Caches"
        let developer = "\(library)/Developer"

        return [
            CacheItem(id: "npm", name: "npm cache", group: .packageManagers, symbol: "shippingbox",
                      detail: "Downloaded packages. npm fetches them again when needed.",
                      paths: ["\(home)/.npm/_cacache"], tier: .safe,
                      method: .command(tool: "npm", arguments: ["cache", "clean", "--force"]), fallback: .deleteContents),
            CacheItem(id: "pnpm-store", name: "pnpm store", group: .packageManagers, symbol: "shippingbox.fill",
                      detail: "Removes only packages no project on this Mac still uses.",
                      paths: ["\(library)/pnpm/store", "\(home)/.local/share/pnpm/store", "\(home)/.pnpm-store"], tier: .safe,
                      method: .command(tool: "pnpm", arguments: ["store", "prune"])),
            CacheItem(id: "pnpm-cache", name: "pnpm metadata cache", group: .packageManagers, symbol: "doc.text.magnifyingglass",
                      detail: "Package metadata. Downloaded again on the next install.",
                      paths: ["\(caches)/pnpm"], tier: .safe, method: .deleteContents),
            CacheItem(id: "yarn", name: "Yarn cache", group: .packageManagers, symbol: "shippingbox",
                      detail: "Downloaded packages for Yarn 1 and Yarn Berry.",
                      paths: ["\(caches)/Yarn", "\(home)/.yarn/berry/cache"], tier: .safe, method: .deleteContents),
            CacheItem(id: "bun", name: "Bun cache", group: .packageManagers, symbol: "shippingbox",
                      detail: "Downloaded packages. Bun fetches them again when needed.",
                      paths: ["\(home)/.bun/install/cache"], tier: .safe, method: .deleteContents),
            CacheItem(id: "homebrew", name: "Homebrew downloads", group: .packageManagers, symbol: "mug",
                      detail: "Old versions and downloaded bottles.",
                      paths: ["\(caches)/Homebrew"], tier: .safe,
                      method: .command(tool: "brew", arguments: ["cleanup", "-s", "--prune=all"]), fallback: .deleteContents),
            CacheItem(id: "cocoapods", name: "CocoaPods cache", group: .packageManagers, symbol: "cube.box",
                      detail: "Downloaded pods. Fetched again on the next pod install.",
                      paths: ["\(caches)/CocoaPods"], tier: .safe,
                      method: .command(tool: "pod", arguments: ["cache", "clean", "--all"]), fallback: .deleteContents),

            CacheItem(id: "derived-data", name: "Xcode DerivedData", group: .apple, symbol: "hammer",
                      detail: "Build products and indexes. Xcode rebuilds them.",
                      paths: ["\(developer)/Xcode/DerivedData"], tier: .safe, method: .deleteContents),
            CacheItem(id: "xcode-previews", name: "SwiftUI previews", group: .apple, symbol: "rectangle.on.rectangle",
                      detail: "Cached preview builds.",
                      paths: ["\(developer)/Xcode/UserData/Previews"], tier: .safe, method: .deleteContents),
            CacheItem(id: "simulator-caches", name: "Simulator caches", group: .apple, symbol: "iphone.gen3",
                      detail: "Shared caches the simulator recreates on boot.",
                      paths: ["\(developer)/CoreSimulator/Caches"], tier: .safe, method: .deleteContents),
            CacheItem(id: "device-support", name: "Device support files", group: .apple, symbol: "cable.connector",
                      detail: "Symbols for connected devices. Copied again when you plug a device in.",
                      paths: ["\(developer)/Xcode/iOS DeviceSupport", "\(developer)/Xcode/watchOS DeviceSupport", "\(developer)/Xcode/tvOS DeviceSupport", "\(developer)/Xcode/visionOS DeviceSupport"],
                      tier: .rebuildable, method: .deleteContents),
            CacheItem(id: "xcode-archives", name: "Xcode archives", group: .apple, symbol: "archivebox",
                      detail: "Builds you archived for release. Keep any you may need to symbolicate.",
                      paths: ["\(developer)/Xcode/Archives"], tier: .review, method: .deleteContents),

            CacheItem(id: "gradle", name: "Gradle caches", group: .languages, symbol: "building.columns",
                      detail: "Dependencies and Gradle distributions. Downloaded again on the next build.",
                      paths: ["\(home)/.gradle/caches", "\(home)/.gradle/wrapper/dists"], tier: .safe, method: .deleteContents),
            CacheItem(id: "maven", name: "Maven repository", group: .languages, symbol: "building.columns",
                      detail: "Downloaded Java dependencies.",
                      paths: ["\(home)/.m2/repository"], tier: .rebuildable, method: .deleteContents),
            CacheItem(id: "pip", name: "pip cache", group: .languages, symbol: "chevron.left.forwardslash.chevron.right",
                      detail: "Downloaded Python wheels.",
                      paths: ["\(caches)/pip"], tier: .safe, method: .deleteContents),
            CacheItem(id: "uv", name: "uv cache", group: .languages, symbol: "chevron.left.forwardslash.chevron.right",
                      detail: "Downloaded Python packages.",
                      paths: ["\(home)/.cache/uv", "\(caches)/uv"], tier: .safe,
                      method: .command(tool: "uv", arguments: ["cache", "clean"]), fallback: .deleteContents),
            CacheItem(id: "go-build", name: "Go build cache", group: .languages, symbol: "chevron.left.forwardslash.chevron.right",
                      detail: "Compiled packages. Go rebuilds them.",
                      paths: ["\(caches)/go-build"], tier: .safe,
                      method: .command(tool: "go", arguments: ["clean", "-cache"]), fallback: .deleteContents),
            CacheItem(id: "cargo", name: "Cargo registry cache", group: .languages, symbol: "gearshape.2",
                      detail: "Downloaded crates. Fetched again on the next build.",
                      paths: ["\(home)/.cargo/registry/cache", "\(home)/.cargo/git/checkouts"], tier: .safe, method: .deleteContents),
            CacheItem(id: "node-gyp", name: "node-gyp headers", group: .languages, symbol: "gearshape",
                      detail: "Node headers for native modules.",
                      paths: ["\(caches)/node-gyp"], tier: .safe, method: .deleteContents),
            CacheItem(id: "typescript", name: "TypeScript cache", group: .languages, symbol: "curlybraces",
                      detail: "Type definitions downloaded by editors.",
                      paths: ["\(caches)/typescript"], tier: .safe, method: .deleteContents),
            CacheItem(id: "deno", name: "Deno cache", group: .languages, symbol: "curlybraces",
                      detail: "Downloaded modules.",
                      paths: ["\(caches)/deno"], tier: .safe, method: .deleteContents),
            CacheItem(id: "electron", name: "Electron downloads", group: .languages, symbol: "bolt",
                      detail: "Electron binaries downloaded by builds.",
                      paths: ["\(caches)/electron", "\(caches)/electron-builder"], tier: .safe, method: .deleteContents),
            CacheItem(id: "android-avd", name: "Android emulators", group: .languages, symbol: "smartphone",
                      detail: "Emulator images and their data. Recreate them in Android Studio.",
                      paths: ["\(home)/.android/avd"], tier: .review, method: .deleteContents),
            CacheItem(id: "android-cache", name: "Android cache", group: .languages, symbol: "smartphone",
                      detail: "SDK manager downloads.",
                      paths: ["\(home)/.android/cache"], tier: .safe, method: .deleteContents),

            CacheItem(id: "playwright", name: "Playwright browsers", group: .testing, symbol: "theatermasks",
                      detail: "Test browsers. Reinstall with npx playwright install.",
                      paths: ["\(caches)/ms-playwright"], tier: .rebuildable, method: .deleteContents),
            CacheItem(id: "puppeteer", name: "Puppeteer browsers", group: .testing, symbol: "theatermasks",
                      detail: "Chrome builds downloaded by Puppeteer.",
                      paths: ["\(home)/.cache/puppeteer"], tier: .rebuildable, method: .deleteContents),
            CacheItem(id: "cypress", name: "Cypress binaries", group: .testing, symbol: "theatermasks",
                      detail: "Downloaded Cypress apps.",
                      paths: ["\(caches)/Cypress"], tier: .rebuildable, method: .deleteContents),
        ] + editorCaches(library: library)
    }

    private static func editorCaches(library: String) -> [CacheItem] {
        let editors: [(id: String, name: String, folder: String, process: String)] = [
            ("vscode", "VS Code", "Code", "Code"),
            ("cursor", "Cursor", "Cursor", "Cursor"),
            ("windsurf", "Windsurf", "Windsurf", "Windsurf"),
        ]
        var items: [CacheItem] = []
        for editor in editors {
            let support = "\(library)/Application Support/\(editor.folder)"
            items.append(CacheItem(
                id: "\(editor.id)-cache", name: "\(editor.name) caches", group: .editors, symbol: "chevron.left.slash.chevron.right",
                detail: "Web caches, downloaded extension packages and logs.",
                paths: ["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs", "Service Worker/CacheStorage", "CachedProfilesData"].map { "\(support)/\($0)" },
                tier: .safe, method: .deleteContents,
                quitApp: editor.process
            ))
            items.append(CacheItem(
                id: "\(editor.id)-orphans", name: "\(editor.name) data for deleted projects", group: .editors, symbol: "folder.badge.questionmark",
                detail: "Workspace storage for folders that no longer exist.",
                paths: orphanedWorkspaceStorage(in: "\(support)/User/workspaceStorage"),
                tier: .safe, method: .deletePaths
            ))
        }
        return items
    }

    /// Workspace storage folders whose project folder has been deleted.
    static func orphanedWorkspaceStorage(in directory: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var orphans: [String] = []
        for entry in entries {
            let folder = "\(directory)/\(entry)"
            guard let data = FileManager.default.contents(atPath: "\(folder)/workspace.json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let target = (json["folder"] ?? json["workspace"]) as? String,
                  let url = URL(string: target), url.isFileURL
            else { continue }
            if !FileManager.default.fileExists(atPath: url.path) {
                orphans.append(folder)
            }
        }
        return orphans
    }

    /// The catalog entry for `id` with live paths and tool locations, ignoring anything stored from a past scan.
    static func trustedItem(id: String) -> CacheItem? {
        guard var item = definitions().first(where: { $0.id == id }) else { return nil }
        item.paths = item.paths.filter { FileManager.default.fileExists(atPath: $0) }
        if case .command(let tool, _) = item.method {
            item.toolPath = ToolLocator.find(tool)
        }
        return item
    }

    /// Measures every cache and resolves the tools that clean them.
    static func scan(runningNames: Set<String>) async -> [CacheItem] {
        let items = definitions().compactMap { item -> CacheItem? in
            var item = item
            item.paths = item.paths.filter { FileManager.default.fileExists(atPath: $0) }
            return item.paths.isEmpty ? nil : item
        }

        let sizes = await DirectorySizer.sizes(of: items.flatMap(\.paths))
        return await offload { resolve(items, sizes: sizes, runningNames: runningNames) }
    }

    private static func resolve(_ measured: [CacheItem], sizes: [String: SizeInfo], runningNames: Set<String>) -> [CacheItem] {
        var items = measured
        for index in items.indices {
            var item = items[index]
            item.size = item.paths.compactMap { sizes[$0] }.reduce(.zero, +)
            if case .command(let tool, _) = item.method {
                item.toolPath = ToolLocator.find(tool)
            }
            if item.id == "pnpm-store" {
                item.size.isEstimate = true
            }
            if let app = item.quitApp, runningNames.contains(app) {
                item.blockedReason = "Quit \(app) first"
            }
            if item.effectiveMethod == nil {
                item.blockedReason = item.blockedReason ?? "\(item.methodToolName ?? "Tool") isn't installed"
            }
            items[index] = item
        }
        return items.filter { $0.size.allocated > 0 }
    }
}

extension CacheItem {
    var methodToolName: String? {
        if case .command(let tool, _) = method { return tool }
        return nil
    }
}
