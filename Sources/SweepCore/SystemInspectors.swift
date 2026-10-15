import Foundation

public enum SimulatorInspector {
    private static let isoFormatter = ISO8601DateFormatter()

    public static func devices() -> [SimulatorDevice] {
        let result = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], timeout: 30)
        guard result.succeeded,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let groups = json["devices"] as? [String: [[String: Any]]]
        else { return [] }

        var devices: [SimulatorDevice] = []
        for (runtimeID, list) in groups {
            let runtime = runtimeName(runtimeID)
            for device in list {
                guard let udid = device["udid"] as? String,
                      let dataPath = device["dataPath"] as? String
                else { continue }
                let bytes = (device["dataPathSize"] as? NSNumber)?.int64Value ?? 0
                let lastBooted = (device["lastBootedAt"] as? String).flatMap(isoFormatter.date(from:))
                devices.append(SimulatorDevice(
                    udid: udid,
                    name: device["name"] as? String ?? "Simulator",
                    runtime: runtime,
                    state: device["state"] as? String ?? "Unknown",
                    isAvailable: device["isAvailable"] as? Bool ?? false,
                    path: (dataPath as NSString).deletingLastPathComponent,
                    size: SizeInfo(allocated: bytes, reclaimable: bytes),
                    lastBooted: lastBooted
                ))
            }
        }
        return devices.sorted { $0.size.reclaimable > $1.size.reclaimable }
    }

    public static func runtimes() -> [SimulatorRuntime] {
        let result = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 30)
        guard result.succeeded,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: [String: Any]]
        else { return [] }

        return json.values.compactMap { runtime -> SimulatorRuntime? in
            guard let identifier = runtime["identifier"] as? String else { return nil }
            let runtimeID = runtime["runtimeIdentifier"] as? String ?? ""
            let version = runtime["version"] as? String
            var name = runtimeName(runtimeID)
            if let version, !name.contains(version) { name += " (\(version))" }
            return SimulatorRuntime(
                id: identifier,
                name: name,
                sizeBytes: (runtime["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                isDeletable: runtime["deletable"] as? Bool ?? false,
                lastUsed: (runtime["lastUsedAt"] as? String).flatMap(isoFormatter.date(from:))
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func runtimeName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return String(last) }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }
}

public enum DockerInspector {
    /// The only Docker commands DevSweep runs, keyed by item id.
    static let commands: [String: [String]] = [
        "docker-build-cache": ["builder", "prune", "-a", "-f"],
        "docker-images": ["image", "prune", "-a", "-f"],
        "docker-containers": ["container", "prune", "-f"],
        "docker-volumes": ["volume", "prune", "-a", "-f"],
    ]

    /// Returns nil when Docker isn't installed, or items plus whether the daemon is running.
    public static func scan() -> (running: Bool, items: [CacheItem])? {
        guard let docker = ToolLocator.find("docker") else { return nil }
        let info = Shell.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 8)
        guard info.succeeded else { return (false, []) }

        let df = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 30)
        guard df.succeeded else { return (true, []) }

        var reclaimable: [String: Int64] = [:]
        var totals: [String: Int64] = [:]
        for line in df.output.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = json["Type"] as? String
            else { continue }
            reclaimable[type] = parseSize(json["Reclaimable"] as? String ?? "")
            totals[type] = parseSize(json["Size"] as? String ?? "")
        }

        func item(_ type: String, id: String, name: String, symbol: String, detail: String, tier: SafetyTier, arguments: [String]) -> CacheItem {
            let bytes = reclaimable[type] ?? 0
            return CacheItem(
                id: id, name: name, group: .docker, symbol: symbol, detail: detail, paths: [],
                tier: tier, method: .command(tool: "docker", arguments: arguments),
                size: SizeInfo(allocated: totals[type] ?? 0, reclaimable: bytes),
                toolPath: docker
            )
        }

        let items = [
            item("Build Cache", id: "docker-build-cache", name: "Build cache", symbol: "hammer.circle",
                 detail: "Layers from past builds. Builds may be slower the first time after.",
                 tier: .safe, arguments: commands["docker-build-cache"]!),
            item("Images", id: "docker-images", name: "Unused images", symbol: "square.stack.3d.up",
                 detail: "Images no container uses. Pulled again when needed.",
                 tier: .rebuildable, arguments: commands["docker-images"]!),
            item("Containers", id: "docker-containers", name: "Stopped containers", symbol: "shippingbox.circle",
                 detail: "Stopped containers and any files written inside them.",
                 tier: .review, arguments: commands["docker-containers"]!),
            item("Local Volumes", id: "docker-volumes", name: "Unused volumes", symbol: "externaldrive.badge.xmark",
                 detail: "Volumes no container uses. These often hold database data.",
                 tier: .review, arguments: commands["docker-volumes"]!),
        ]
        return (true, items.filter { $0.size.reclaimable > 0 })
    }

    /// Reads "Total reclaimed space: 1.2GB" from a prune command's output.
    static func reclaimed(in output: String) -> Int64? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("reclaimed space") }),
              let value = line.split(separator: ":").last
        else { return nil }
        return parseSize(value.trimmingCharacters(in: .whitespaces))
    }

    /// Parses Docker's decimal sizes such as "27.25GB (93%)" or "163.8kB".
    static func parseSize(_ text: String) -> Int64 {
        let value = text.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, multiplier) in units where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count)) else { return 0 }
            return Int64(number * multiplier)
        }
        return 0
    }
}

public enum SystemInfo {
    public static func disk(for path: String = NSHomeDirectory()) -> DiskUsage? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity
        else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return DiskUsage(total: Int64(total), available: available)
    }

    public static func hasLocalSnapshots() -> Bool {
        let result = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 10)
        return result.output.split(separator: "\n").contains { $0.contains("com.apple.TimeMachine") }
    }

    /// True when the app can read folders protected by Full Disk Access.
    public static func hasFullDiskAccess() -> Bool {
        let probes = [
            "\(NSHomeDirectory())/Library/Safari",
            "\(NSHomeDirectory())/Library/Containers/com.apple.stocks",
            "/Library/Application Support/com.apple.TCC",
        ]
        for probe in probes where FileManager.default.fileExists(atPath: probe) {
            return (try? FileManager.default.contentsOfDirectory(atPath: probe)) != nil
        }
        return true
    }

    public static var trashPath: String { "\(NSHomeDirectory())/.Trash" }
}

public struct TrashEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isFolder: Bool
    public let size: SizeInfo
    public let dateAdded: Date?
}

public enum TrashInspector {
    /// Items in your Trash, largest first, or nil when macOS doesn't let DevSweep read it.
    public static func entries() async -> [TrashEntry]? {
        let trash = SystemInfo.trashPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trash) else { return nil }
        let paths = names.filter { $0 != ".DS_Store" && $0 != ".localized" }.map { trash + "/" + $0 }
        let sizes = await DirectorySizer.sizes(of: paths)

        return paths.map { path in
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey])
            return TrashEntry(
                path: path,
                name: url.lastPathComponent,
                isFolder: (values?.isDirectory ?? false) && !(values?.isPackage ?? false),
                size: sizes[path] ?? .zero,
                dateAdded: values?.addedToDirectoryDate
            )
        }
        .sorted { $0.size.allocated > $1.size.allocated }
    }
}
