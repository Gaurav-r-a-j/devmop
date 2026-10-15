import Foundation

/// Developer leftovers beyond package caches: AI models, old runtimes, obsolete extensions and Xcode extras.
enum DeveloperExtras {
    static func definitions(home: String) -> [CacheItem] {
        let developer = "\(home)/Library/Developer"
        var items: [CacheItem] = [
            CacheItem(id: "huggingface", name: "Hugging Face models", group: .aiModels, symbol: "brain",
                      detail: "Models and datasets downloaded by transformers and diffusers. Downloaded again when a script needs them.",
                      paths: ["\(home)/.cache/huggingface/hub", "\(home)/.cache/huggingface/datasets"], tier: .review, method: .deleteContents),
            CacheItem(id: "ollama", name: "Ollama models", group: .aiModels, symbol: "brain.head.profile",
                      detail: "Every model you pulled with Ollama. Pull them again to use them.",
                      paths: ["\(home)/.ollama/models"], tier: .review, method: .deleteContents, quitApp: "ollama"),
            CacheItem(id: "lmstudio", name: "LM Studio models", group: .aiModels, symbol: "cpu",
                      detail: "Models downloaded in LM Studio. Download them again from the app.",
                      paths: ["\(home)/.lmstudio/models", "\(home)/.cache/lm-studio/models"], tier: .review, method: .deleteContents,
                      quitApp: "LM Studio"),
            CacheItem(id: "torch", name: "PyTorch & Whisper downloads", group: .aiModels, symbol: "flame",
                      detail: "Weights fetched by torch.hub and Whisper. Downloaded again on first use.",
                      paths: ["\(home)/.cache/torch", "\(home)/.cache/whisper"], tier: .review, method: .deleteContents),

            CacheItem(id: "xcode-docs", name: "Xcode documentation cache", group: .apple, symbol: "book",
                      detail: "Downloaded developer documentation. Xcode fetches it again.",
                      paths: ["\(developer)/Xcode/DocumentationCache"], tier: .safe, method: .deleteContents),
            CacheItem(id: "xcode-device-logs", name: "Device logs", group: .apple, symbol: "doc.text.magnifyingglass",
                      detail: "Crash and console logs copied from connected devices.",
                      paths: ["\(developer)/Xcode/iOS Device Logs"], tier: .safe, method: .deleteContents),

            CacheItem(id: "android-images", name: "Android system images", group: .languages, symbol: "smartphone",
                      detail: "Emulator OS images. Install them again from Android Studio's SDK Manager.",
                      paths: ["\(home)/Library/Android/sdk/system-images"], tier: .review, method: .deleteContents),
        ]

        let oldNode = oldNodeVersions(home: home)
        if !oldNode.isEmpty {
            items.append(CacheItem(id: "nvm-old", name: "Old Node.js versions", group: .languages, symbol: "hexagon",
                                   detail: "Node versions installed with nvm other than your default and the newest. Reinstall with nvm install.",
                                   paths: oldNode, tier: .review, method: .deletePaths))
        }

        let editors: [(id: String, name: String, folder: String, process: String)] = [
            ("vscode", "VS Code", ".vscode", "Code"),
            ("cursor", "Cursor", ".cursor", "Cursor"),
            ("windsurf", "Windsurf", ".windsurf", "Windsurf"),
        ]
        for editor in editors {
            let obsolete = obsoleteExtensions(in: "\(home)/\(editor.folder)/extensions")
            guard !obsolete.isEmpty else { continue }
            items.append(CacheItem(id: "\(editor.id)-old-extensions", name: "\(editor.name) old extension versions", group: .editors,
                                   symbol: "puzzlepiece.extension",
                                   detail: "Versions \(editor.name) already replaced and marked for removal.",
                                   paths: obsolete, tier: .safe, method: .deletePaths, quitApp: editor.process))
        }
        return items
    }

    /// nvm-installed versions, keeping the default alias and the newest.
    static func oldNodeVersions(home: String) -> [String] {
        let base = "\(home)/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        let installed = versions.filter { $0.hasPrefix("v") }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        guard installed.count > 1, let newest = installed.last else { return [] }

        var keep: Set<String> = [newest]
        let alias = (try? String(contentsOfFile: "\(home)/.nvm/alias/default", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch alias {
        case "", "node", "stable":
            break
        case let name where name.hasPrefix("lts"):
            // An LTS alias can't be resolved offline, so nothing is offered.
            return []
        default:
            let wanted = alias.hasPrefix("v") ? alias : "v" + alias
            guard let match = installed.last(where: { $0 == wanted || $0.hasPrefix(wanted + ".") }) else { return [] }
            keep.insert(match)
        }
        return installed.filter { !keep.contains($0) }.map { "\(base)/\($0)" }
    }

    /// Extension folders the editor listed in its .obsolete file and that still exist.
    static func obsoleteExtensions(in directory: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: "\(directory)/.obsolete"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return json.compactMap { name, value -> String? in
            guard (value as? Bool) == true, !name.contains("/"), !name.hasPrefix(".") else { return nil }
            let path = "\(directory)/\(name)"
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        .sorted()
    }
}

/// iCloud Drive files that are downloaded, fully uploaded and safe to keep only in iCloud.
enum ICloudDownloads {
    static let id = "icloud-downloads"
    static let minimumSize: Int64 = 5_000_000

    static func root(home: String) -> String { "\(home)/Library/Mobile Documents" }

    static func item(home: String) -> CacheItem? {
        let files = evictableFiles(under: root(home: home))
        guard !files.isEmpty else { return nil }
        return CacheItem(
            id: id, name: "iCloud Drive downloads", group: .system, symbol: "icloud.and.arrow.down",
            detail: "\(files.count) files already safe in iCloud. Removing the download keeps them in iCloud; they download again when you open them.",
            paths: files, tier: .rebuildable, method: .evictDownloads
        )
    }

    static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey,
        .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemIsSharedKey, .isRegularFileKey, .isPackageKey,
        .totalFileAllocatedSizeKey,
    ]

    static func evictableFiles(under root: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true || values.isPackage == true,
                  isEvictable(values),
                  Int64(values.totalFileAllocatedSize ?? 0) >= minimumSize
            else { continue }
            files.append(url.path)
        }
        return files
    }

    static func isEvictable(_ values: URLResourceValues) -> Bool {
        values.isUbiquitousItem == true
            && values.ubiquitousItemDownloadingStatus == .current
            && values.ubiquitousItemIsUploaded == true
            && values.ubiquitousItemHasUnresolvedConflicts != true
    }

    /// Checks a file again right before removing its download.
    static func recheck(_ path: String, home: String = NSHomeDirectory()) -> String? {
        guard path.isInside(root(home: home)), !path.split(separator: "/").contains("..") else { return "Not in iCloud Drive" }
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return "Already gone" }
        guard values.isUbiquitousItem == true else { return "Not an iCloud file" }
        guard values.ubiquitousItemIsUploaded == true else { return "Not uploaded to iCloud yet" }
        guard values.ubiquitousItemHasUnresolvedConflicts != true else { return "Has a sync conflict" }
        guard values.ubiquitousItemDownloadingStatus == .current else { return "Already only in iCloud" }
        if values.isRegularFile == true, UserFiles.isOpen(path) { return "Open in an app" }
        return nil
    }
}
