import CoreServices
import CryptoKit
import Darwin
import Foundation

public enum UserFileReason: String, Codable, Hashable, Sendable, CaseIterable {
    case large
    case installer
    case extractedArchive
    case oldDownload
    case duplicate

    public var title: String {
        switch self {
        case .large: "Large"
        case .installer: "Installer"
        case .extractedArchive: "Already extracted"
        case .oldDownload: "Not opened in 3+ months"
        case .duplicate: "Duplicate"
        }
    }
}

public struct UserFile: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    /// Bytes on disk.
    public let allocated: Int64
    /// Bytes deleting it frees; less than allocated for APFS clones.
    public let reclaimable: Int64
    public let modified: Date?
    public let lastOpened: Date?
    public var reasons: [UserFileReason]
    /// For duplicates: the content hash shared by every copy.
    public var contentHash: String?
    public var otherCopies: [String]?

    public var lastUsed: Date? { lastOpened ?? modified }
}

/// Finds large, old, leftover and duplicate files in your own folders.
public enum UserFiles {
    public static let largeThreshold: Int64 = 250_000_000
    static let duplicateThreshold: Int64 = 1_000_000
    static let oldAfter: TimeInterval = 90 * 24 * 3600

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z"]

    public static func folders(home: String = NSHomeDirectory()) -> [String] {
        ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { "\(home)/\($0)" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    struct Candidate {
        let path: String
        let allocated: Int64
        let reclaimable: Int64
        let modified: TimeInterval
        let inode: UInt64
    }

    public static func scan(home: String = NSHomeDirectory(), now: Date = Date()) -> [UserFile] {
        let roots = folders(home: home)
        let downloads = "\(home)/Downloads"
        let candidates = Parallel.map(roots, width: roots.count) { root in
            var found: [Candidate] = []
            let fd = BulkDirectory.openDirectory(root)
            guard fd >= 0 else { return found }
            walk(fd: fd, path: root, depth: 0, into: &found)
            close(fd)
            return found
        }
        .flatMap { $0 }
        .filter { !isDataless($0.path) }

        var files: [String: UserFile] = [:]
        func add(_ candidate: Candidate, _ reason: UserFileReason) {
            if var existing = files[candidate.path] {
                if !existing.reasons.contains(reason) { existing.reasons.append(reason) }
                files[candidate.path] = existing
                return
            }
            files[candidate.path] = UserFile(
                path: candidate.path,
                name: (candidate.path as NSString).lastPathComponent,
                allocated: candidate.allocated,
                reclaimable: candidate.reclaimable,
                modified: Date(timeIntervalSince1970: candidate.modified),
                lastOpened: lastOpened(candidate.path),
                reasons: [reason]
            )
        }

        for candidate in candidates where candidate.allocated >= largeThreshold {
            add(candidate, .large)
        }

        let downloadNames = Set((try? FileManager.default.contentsOfDirectory(atPath: downloads)) ?? [])
        for candidate in candidates where (candidate.path as NSString).deletingLastPathComponent == downloads {
            let name = (candidate.path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            if installerExtensions.contains(ext) {
                add(candidate, .installer)
            } else if archiveExtensions.contains(ext), downloadNames.contains(archiveBaseName(name)) {
                add(candidate, .extractedArchive)
            }
            let used = lastOpened(candidate.path) ?? Date(timeIntervalSince1970: candidate.modified)
            if candidate.allocated >= 1_000_000, now.timeIntervalSince(used) > oldAfter {
                add(candidate, .oldDownload)
            }
        }

        for group in duplicateGroups(candidates) {
            for candidate in group.members {
                add(candidate, .duplicate)
                files[candidate.path]?.contentHash = group.hash
                files[candidate.path]?.otherCopies = group.members.map(\.path).filter { $0 != candidate.path }
            }
        }

        return files.values.sorted { $0.allocated > $1.allocated }
    }

    // MARK: Walking

    private static func walk(fd: Int32, path: String, depth: Int, into found: inout [Candidate]) {
        var subdirectories: [String] = []
        BulkDirectory.forEach(in: fd) { entry in
            if entry.name.hasPrefix(".") { return }
            switch entry.kind {
            case .directory:
                let ext = (entry.name as NSString).pathExtension.lowercased()
                if Rules.packageExtensions.contains(ext) || Rules.rulesByDirectory[entry.name] != nil { return }
                subdirectories.append(entry.name)
            case .file:
                guard entry.allocatedSize >= duplicateThreshold, entry.linkCount <= 1 else { return }
                found.append(Candidate(
                    path: path + "/" + entry.name,
                    allocated: entry.allocatedSize,
                    reclaimable: min(entry.privateSize ?? entry.allocatedSize, entry.allocatedSize),
                    modified: entry.modified,
                    inode: entry.inode
                ))
            case .symlink, .other:
                return
            }
        }
        guard depth < 20 else { return }
        for name in subdirectories {
            let child = BulkDirectory.openDirectory(name, in: fd)
            guard child >= 0 else { continue }
            walk(fd: child, path: path + "/" + name, depth: depth + 1, into: &found)
            close(child)
        }
    }

    /// "photos.tar.gz" → "photos", the folder an archive usually extracts to.
    static func archiveBaseName(_ name: String) -> String {
        var base = name
        while archiveExtensions.contains((base as NSString).pathExtension.lowercased()) {
            base = (base as NSString).deletingPathExtension
        }
        return base
    }

    /// iCloud files that live only in the cloud; reading them would download them.
    static func isDataless(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return true }
        return st.st_flags & UInt32(SF_DATALESS) != 0
    }

    static func lastOpened(_ path: String) -> Date? {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: Duplicates

    struct DuplicateGroup {
        let hash: String
        let members: [Candidate]
    }

    static func duplicateGroups(_ candidates: [Candidate]) -> [DuplicateGroup] {
        let bySize = Dictionary(grouping: candidates) { logicalSize($0.path) ?? -1 }
            .filter { $0.key > 0 && $0.value.count > 1 }

        var groups: [DuplicateGroup] = []
        for (_, sameSize) in bySize {
            let unique = Dictionary(grouping: sameSize, by: \.inode).compactMap(\.value.first)
            guard unique.count > 1 else { continue }
            let byQuick = Dictionary(grouping: unique) { quickHash($0.path) ?? UUID().uuidString }
            for (_, quickMatches) in byQuick where quickMatches.count > 1 {
                let byFull = Dictionary(grouping: quickMatches) { fullHash($0.path) ?? UUID().uuidString }
                for (hash, members) in byFull where members.count > 1 {
                    groups.append(DuplicateGroup(hash: hash, members: members.sorted { $0.path < $1.path }))
                }
            }
        }
        return groups
    }

    static func logicalSize(_ path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(st.st_size)
    }

    /// Hash of the first and last 64 KB, to rule out most non-duplicates cheaply.
    static func quickHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        if let head = try? handle.read(upToCount: 65_536) { hasher.update(data: head) }
        if let end = try? handle.seekToEnd(), end > 65_536 {
            try? handle.seek(toOffset: end - 65_536)
            if let tail = try? handle.read(upToCount: 65_536) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func fullHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 4 * 1_048_576)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Safety

    /// Whether any process has the file open.
    public static func isOpen(_ path: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
                                      &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return bytes > 0
    }

    /// Checks a file right before it goes to the Trash.
    static func recheck(_ file: UserFile, home: String = NSHomeDirectory()) -> String? {
        let path = file.path
        let components = path.split(separator: "/")
        guard path.hasPrefix("/"), !components.contains(".."),
              folders(home: home).contains(where: { path.isInside($0) && path.resolvedPath.isInside($0.resolvedPath) }),
              !components.dropFirst(home.split(separator: "/").count).contains(where: { $0.hasPrefix(".") })
        else { return "Outside your personal folders" }
        if let problem = Cleaner.unsafeLocation(path) { return problem }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "Already gone" }
        guard st.st_mode & S_IFMT == S_IFREG else { return "No longer a regular file" }
        if st.st_flags & UInt32(SF_DATALESS) != 0 { return "Only in iCloud" }
        if st.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return "Locked" }
        let allocated = Int64(st.st_blocks) * 512
        if abs(allocated - file.allocated) > max(file.allocated / 100, 65_536) { return "Changed since the scan" }
        if isOpen(path) { return "Open in an app" }
        return nil
    }
}
