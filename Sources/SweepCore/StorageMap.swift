import Foundation

/// One area of the disk shown on the Overview, such as Documents or Applications.
public struct StorageSlice: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case documents, desktop, downloads, pictures, movies, music, iCloud, mail, applications, otherFolders, developerTools
    }

    public var id: String { kind.rawValue }
    public let kind: Kind
    public let paths: [String]
    public var size: SizeInfo
    /// Size of each path, so unchanged folders can be reused next scan.
    public var parts: [String: SizeInfo]?
}

/// Measures where the rest of the disk goes: your folders, apps, iCloud and mail.
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
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let type = try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType, type == .typeSymbolicLink { continue }
            if entry.hasPrefix(".") { developer.append(path) } else { other.append(path) }
        }

        var layout = named.map { (kind: $0.key, paths: ["\(home)/\($0.value)"]) }
        layout += [
            (.iCloud, ["\(home)/Library/Mobile Documents"]),
            (.mail, ["\(home)/Library/Mail", "\(home)/Library/Messages"]),
            (.applications, ["/Applications", "\(home)/Applications"]),
            (.otherFolders, other.sorted().flatMap(children)),
            (.developerTools, developer.sorted().flatMap(children)),
        ]
        return layout.map { slice in
            (slice.kind, slice.paths.filter { fileManager.fileExists(atPath: $0) })
        }
    }

    /// A busy folder's entries, so a rescan only re-measures the ones that changed.
    private static func children(of path: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path), names.count <= 2_000 else { return [path] }
        return names.map { "\(path)/\($0)" }
    }

    static func measure(home: String = NSHomeDirectory(), reuse: SizeReuse?) async -> [StorageSlice] {
        let layout = layout(home: home)
        let paths = layout.flatMap(\.paths)
        var sizes: [String: SizeInfo] = [:]
        var toMeasure: [String] = []
        for path in paths {
            if let cached = reuse?.cached(path) { sizes[path] = cached } else { toMeasure.append(path) }
        }
        sizes.merge(await DirectorySizer.sizes(of: toMeasure, concurrency: 6)) { _, new in new }

        return layout.map { slice in
            StorageSlice(kind: slice.kind, paths: slice.paths, size: slice.paths.compactMap { sizes[$0] }.reduce(.zero, +),
                         parts: Dictionary(uniqueKeysWithValues: slice.paths.compactMap { path in sizes[path].map { (path, $0) } }))
        }
    }
}
