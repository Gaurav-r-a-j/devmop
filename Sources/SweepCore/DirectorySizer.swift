import Darwin
import Foundation

/// Measures folders, counting only the space deletion would actually free.
public enum DirectorySizer {
    private static let fanOutTarget = ProcessInfo.processInfo.activeProcessorCount * 4

    public static func size(of path: String) -> SizeInfo {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .zero }
        if st.st_mode & S_IFMT != S_IFDIR {
            let bytes = Int64(st.st_blocks) * 512
            return SizeInfo(allocated: bytes, reclaimable: st.st_nlink > 1 ? 0 : bytes, fileCount: 1)
        }

        var tally = Tally()
        var frontier = [path]
        for _ in 0..<3 where !frontier.isEmpty && frontier.count < fanOutTarget {
            var next: [String] = []
            for directory in frontier {
                let fd = BulkDirectory.openDirectory(directory)
                guard fd >= 0 else {
                    tally.unreadable += 1
                    continue
                }
                list(fd: fd, tally: &tally) { next.append(directory + "/" + $0) }
                close(fd)
            }
            frontier = next
        }

        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: frontier.count) { index in
            var local = Tally()
            let fd = BulkDirectory.openDirectory(frontier[index])
            if fd >= 0 {
                walk(fd: fd, depth: 0, tally: &local)
                close(fd)
            } else {
                local.unreadable += 1
            }
            lock.lock()
            tally.merge(local)
            lock.unlock()
        }
        return tally.result
    }

    public static func size(of paths: [String]) -> SizeInfo {
        paths.reduce(SizeInfo.zero) { $0 + size(of: $1) }
    }

    /// Sizes many folders, a few at a time, returning results keyed by path.
    public static func sizes(of paths: [String], concurrency: Int = 4, onEach: (@Sendable (String, SizeInfo) -> Void)? = nil) async -> [String: SizeInfo] {
        await offload {
            let infos = Parallel.map(paths, width: concurrency) { path in
                let info = size(of: path)
                onEach?(path, info)
                return info
            }
            return Dictionary(zip(paths, infos), uniquingKeysWith: { first, _ in first })
        }
    }

    private struct Tally {
        var allocated: Int64 = 0
        var reclaimable: Int64 = 0
        var files = 0
        var unreadable = 0
        var sawPrivateSize = false
        var missingPrivateSize = false
        var hardlinks: [UInt64: (seen: UInt32, links: UInt32, bytes: Int64)] = [:]

        mutating func merge(_ other: Tally) {
            allocated += other.allocated
            reclaimable += other.reclaimable
            files += other.files
            unreadable += other.unreadable
            sawPrivateSize = sawPrivateSize || other.sawPrivateSize
            missingPrivateSize = missingPrivateSize || other.missingPrivateSize
            for (inode, entry) in other.hardlinks {
                if let known = hardlinks[inode] {
                    hardlinks[inode] = (known.seen + entry.seen, known.links, known.bytes)
                } else {
                    hardlinks[inode] = entry
                }
            }
        }

        var result: SizeInfo {
            var total = allocated
            var freed = reclaimable
            for entry in hardlinks.values {
                total += entry.bytes
                if entry.seen >= entry.links { freed += entry.bytes }
            }
            return SizeInfo(
                allocated: total,
                reclaimable: freed,
                fileCount: files,
                isEstimate: missingPrivateSize && !sawPrivateSize,
                unreadableCount: unreadable
            )
        }
    }

    private static func list(fd: Int32, tally: inout Tally, onDirectory: (String) -> Void) {
        let ok = BulkDirectory.forEach(in: fd) { entry in
            if entry.kind == .directory {
                onDirectory(entry.name)
                return
            }
            tally.files += 1
            if entry.linkCount > 1 {
                if var known = tally.hardlinks[entry.inode] {
                    known.seen += 1
                    tally.hardlinks[entry.inode] = known
                } else {
                    tally.hardlinks[entry.inode] = (1, entry.linkCount, entry.allocatedSize)
                }
            } else {
                tally.allocated += entry.allocatedSize
                if let privateSize = entry.privateSize {
                    tally.sawPrivateSize = true
                    tally.reclaimable += min(privateSize, entry.allocatedSize)
                } else {
                    if entry.kind == .file { tally.missingPrivateSize = true }
                    tally.reclaimable += entry.allocatedSize
                }
            }
        }
        if !ok { tally.unreadable += 1 }
    }

    private static func walk(fd: Int32, depth: Int, tally: inout Tally) {
        var subdirectories: [String] = []
        list(fd: fd, tally: &tally) { subdirectories.append($0) }
        guard depth < 256 else { return }

        for name in subdirectories {
            let child = BulkDirectory.openDirectory(name, in: fd)
            guard child >= 0 else {
                tally.unreadable += 1
                continue
            }
            walk(fd: child, depth: depth + 1, tally: &tally)
            close(child)
        }
    }
}
