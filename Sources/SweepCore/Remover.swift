import Darwin
import Foundation

/// Deletes a file or folder tree without following links; items it can't remove are skipped and counted.
enum Remover {
    struct Result {
        var freed: Int64 = 0
        var skipped = 0
    }

    static func remove(_ path: String) -> Result {
        var st = stat()
        guard lstat(path, &st) == 0 else { return Result() }
        let before = DirectorySizer.size(of: path).reclaimable

        var skipped = 0
        if st.st_mode & S_IFMT == S_IFDIR {
            let fd = BulkDirectory.openDirectory(path)
            if fd >= 0 {
                skipped = removeContents(of: fd, device: st.st_dev)
                close(fd)
                if rmdir(path) != 0, skipped == 0 { skipped = 1 }
            } else {
                skipped = 1
            }
        } else if unlink(path) != 0 {
            skipped = 1
        }

        var remaining = stat()
        let after = lstat(path, &remaining) == 0 ? DirectorySizer.size(of: path).reclaimable : 0
        return Result(freed: max(0, before - after), skipped: skipped)
    }

    /// Stays on the starting volume, so a disk mounted inside the folder is never emptied.
    private static func removeContents(of fd: Int32, device: dev_t) -> Int {
        var entries: [DirEntry] = []
        BulkDirectory.forEach(in: fd) { entries.append($0) }

        var skipped = 0
        for entry in entries {
            if entry.kind == .directory {
                let child = BulkDirectory.openDirectory(entry.name, in: fd)
                guard child >= 0 else {
                    skipped += 1
                    continue
                }
                var childStat = stat()
                guard fstat(child, &childStat) == 0, childStat.st_dev == device else {
                    close(child)
                    skipped += 1
                    continue
                }
                let inside = removeContents(of: child, device: device)
                close(child)
                skipped += inside
                if unlinkat(fd, entry.name, AT_REMOVEDIR) != 0, inside == 0 { skipped += 1 }
            } else if unlinkat(fd, entry.name, 0) != 0 {
                skipped += 1
            }
        }
        return skipped
    }
}
