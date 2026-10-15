import Darwin
import Foundation

/// One area of the disk shown on the Overview and the Storage Map, such as Documents or the macOS volume.
public struct StorageSlice: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case documents, desktop, downloads, pictures, movies, music, iCloud, mail, applications, otherFolders, developerTools
        case cloudStorage, libraryCaches, libraryAppSupport, libraryContainers, libraryDeveloper, libraryOther
        case homebrew, systemLibrary, macOS, swap, preboot
    }

    public var id: String { kind.rawValue }
    public let kind: Kind
    public let paths: [String]
    public var size: SizeInfo
    /// Size of each path, so unchanged folders can be reused next scan.
    public var parts: [String: SizeInfo]?
}

/// Measures where the rest of the disk goes: your folders, apps, Library, Homebrew and macOS itself.
public enum StorageMap {
    static func layout(home: String) -> [(kind: StorageSlice.Kind, paths: [String])] {
        let fileManager = FileManager.default
        let named: [StorageSlice.Kind: String] = [
            .documents: "Documents", .desktop: "Desktop", .downloads: "Downloads",
            .pictures: "Pictures", .movies: "Movies", .music: "Music",
        ]
        let entries = (try? fileManager.contentsOfDirectory(atPath: home)) ?? []
        let skipped: Set<String> = ["Library", ".Trash", "Applications", "Public"]
        var other: [String] = []
        var developer: [String] = []
        for entry in entries where !skipped.contains(entry) && !named.values.contains(entry) {
            let path = "\(home)/\(entry)"
            guard isRealDirectory(path) else { continue }
            if entry.hasPrefix(".") { developer.append(path) } else { other.append(path) }
        }

        let library = "\(home)/Library"
        let libraryHandled: Set<String> = [
            "Caches", "Application Support", "Containers", "Group Containers", "Developer",
            "Mail", "Messages", "Mobile Documents", "CloudStorage",
        ]
        let libraryOther = ((try? fileManager.contentsOfDirectory(atPath: library)) ?? [])
            .filter { !libraryHandled.contains($0) }
            .map { "\(library)/\($0)" }

        var layout = named.map { (kind: $0.key, paths: ["\(home)/\($0.value)"]) }
        layout += [
            (.iCloud, ["\(library)/Mobile Documents"]),
            (.mail, ["\(library)/Mail", "\(library)/Messages"]),
            (.applications, ["/Applications", "\(home)/Applications"]),
            (.otherFolders, other.sorted().flatMap(children)),
            (.developerTools, developer.sorted().flatMap(children)),
            (.cloudStorage, children(of: "\(library)/CloudStorage")),
            (.libraryCaches, children(of: "\(library)/Caches")),
            (.libraryAppSupport, children(of: "\(library)/Application Support")),
            (.libraryContainers, children(of: "\(library)/Containers") + children(of: "\(library)/Group Containers")),
            (.libraryDeveloper, children(of: "\(library)/Developer")),
            (.libraryOther, libraryOther.sorted().flatMap { isRealDirectory($0) ? children(of: $0) : [$0] }),
            (.homebrew, ["/opt/homebrew", "/usr/local/Homebrew", "/usr/local/Cellar"].flatMap(children)),
            (.systemLibrary, systemLibraryPaths()),
        ]
        return layout.map { slice in
            (slice.kind, slice.paths.filter { fileManager.fileExists(atPath: $0) })
        }
    }

    /// /Library without mounted simulator runtimes, which are counted under Simulators.
    private static func systemLibraryPaths() -> [String] {
        children(of: "/Library").flatMap { path -> [String] in
            guard path == "/Library/Developer" else { return [path] }
            return children(of: path).flatMap { inner -> [String] in
                guard inner == "/Library/Developer/CoreSimulator" else { return [inner] }
                return children(of: inner).filter { !$0.hasSuffix("/Volumes") && !$0.hasSuffix("/Images") }
            }
        }
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// A folder's entries, so a rescan only re-measures the ones that changed.
    private static func children(of path: String) -> [String] {
        guard isRealDirectory(path) else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path), names.count <= 2_000 else { return [path] }
        return names.map { "\(path)/\($0)" }
    }

    static func measure(home: String = NSHomeDirectory(), reuse: SizeReuse?) async -> [StorageSlice] {
        let layout = layout(home: home)
        let paths = layout.flatMap(\.paths)
        let measured = await offload {
            Parallel.map(paths, width: 6) { path -> [String: SizeInfo] in
                var parts: [String: SizeInfo] = [:]
                _ = measureAdaptive(path, reuse: reuse, depth: 0, parts: &parts)
                return parts
            }
        }
        let parts = measured.reduce(into: [String: SizeInfo]()) { $0.merge($1) { first, _ in first } }

        var slices = layout.map { slice in
            let own = parts.filter { key, _ in slice.paths.contains { key.isInside($0) } }
            return StorageSlice(kind: slice.kind, paths: slice.paths, size: slice.paths.compactMap { parts[$0] }.reduce(.zero, +), parts: own)
        }
        let volumes = await offload { systemVolumes() }
        let systemSlices: [(StorageSlice.Kind, Int64)] = [
            (.macOS, volumes["System"] ?? 0),
            (.swap, volumes["VM"] ?? 0),
            (.preboot, (volumes["Preboot"] ?? 0) + (volumes["Recovery"] ?? 0) + (volumes["Update"] ?? 0)),
        ]
        for (kind, used) in systemSlices {
            slices.append(StorageSlice(kind: kind, paths: [], size: SizeInfo(allocated: used, reclaimable: 0)))
        }
        return slices
    }

    /// Re-measures a changed folder; if it was big last time, goes one level deeper so only its changed parts are re-measured.
    static func measureAdaptive(_ path: String, reuse: SizeReuse?, depth: Int, parts: inout [String: SizeInfo]) -> SizeInfo {
        if let cached = reuse?.cached(path) {
            parts[path] = cached
            return cached
        }
        if depth < 4, let previous = reuse?.sizes[path], previous.fileCount > 20_000, isRealDirectory(path),
           let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
            var total = DirectorySizer.shallowSize(of: path)
            for name in names {
                let child = path + "/" + name
                guard isRealDirectory(child) else { continue }
                total = total + measureAdaptive(child, reuse: reuse, depth: depth + 1, parts: &parts)
            }
            parts[path] = total
            return total
        }
        let size = DirectorySizer.size(of: path)
        parts[path] = size
        return size
    }

    /// Space used by each APFS volume role (System, VM, Preboot…) in the container that holds macOS.
    static func systemVolumes() -> [String: Int64] {
        let result = Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 15)
        guard result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]]
        else { return [:] }

        for container in containers {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            let roles = volumes.flatMap { $0["Roles"] as? [String] ?? [] }
            guard roles.contains("System") else { continue }
            var usage: [String: Int64] = [:]
            for volume in volumes {
                let bytes = (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                for role in volume["Roles"] as? [String] ?? [] { usage[role, default: 0] += bytes }
            }
            return usage
        }
        return [:]
    }
}
