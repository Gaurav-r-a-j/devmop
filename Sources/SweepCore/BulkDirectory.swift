import Darwin
import Foundation

struct DirEntry {
    enum Kind { case file, directory, symlink, other }

    let name: String
    let kind: Kind
    let inode: UInt64
    let linkCount: UInt32
    let allocatedSize: Int64
    /// Bytes only this file owns on APFS (clones share the rest); nil when unknown.
    let privateSize: Int64?
    let modified: TimeInterval
}

/// Reads directory entries with getattrlistbulk, falling back to readdir + fstatat.
enum BulkDirectory {
    private static let attrCmnReturned: attrgroup_t = 0x8000_0000
    private static let attrCmnName: attrgroup_t = 0x0000_0001
    private static let attrCmnObjType: attrgroup_t = 0x0000_0008
    private static let attrCmnModTime: attrgroup_t = 0x0000_0400
    private static let attrCmnFileID: attrgroup_t = 0x0200_0000
    private static let attrCmnError: attrgroup_t = 0x2000_0000
    private static let attrFileLinkCount: attrgroup_t = 0x0000_0001
    private static let attrFileAllocSize: attrgroup_t = 0x0000_0004
    private static let attrCmnExtPrivateSize: attrgroup_t = 0x0000_0008
    private static let fsoptAttrCmnExtended: UInt64 = 0x0000_0020

    private static let vReg: UInt32 = 1
    private static let vDir: UInt32 = 2
    private static let vLnk: UInt32 = 5

    private static let bufferSize = 256 * 1024

    static func openDirectory(_ path: String) -> Int32 {
        open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    static func openDirectory(_ name: String, in parent: Int32) -> Int32 {
        openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    /// Calls `body` for each entry in the open directory. Returns false if the directory could not be read.
    @discardableResult
    static func forEach(in fd: Int32, _ body: (DirEntry) -> Void) -> Bool {
        switch bulkList(fd: fd, extended: true, body) {
        case .ok: return true
        case .failed(let code) where code == EINVAL:
            switch bulkList(fd: fd, extended: false, body) {
            case .ok: return true
            case .failed: return fallbackList(fd: fd, body)
            }
        case .failed(let code) where code == ENOTSUP:
            return fallbackList(fd: fd, body)
        case .failed:
            return false
        }
    }

    private enum BulkResult { case ok, failed(Int32) }

    private static func bulkList(fd: Int32, extended: Bool, _ body: (DirEntry) -> Void) -> BulkResult {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrCmnReturned | attrCmnName | attrCmnError | attrCmnObjType | attrCmnModTime | attrCmnFileID
        attrs.fileattr = attrFileLinkCount | attrFileAllocSize
        if extended { attrs.forkattr = attrCmnExtPrivateSize }
        let options: UInt64 = extended ? fsoptAttrCmnExtended : 0

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, options)
            if count < 0 { return .failed(errno) }
            if count == 0 { return .ok }

            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let parsed = parse(entry: entry, extended: extended) {
                    body(parsed)
                }
                entry += length
            }
        }
    }

    private static func parse(entry: UnsafeMutableRawPointer, extended: Bool) -> DirEntry? {
        var p = entry + 4
        let common = p.loadUnaligned(as: UInt32.self)
        let file = (p + 12).loadUnaligned(as: UInt32.self)
        let fork = (p + 16).loadUnaligned(as: UInt32.self)
        p += 20

        if common & attrCmnError != 0 {
            let error = p.loadUnaligned(as: UInt32.self)
            p += 4
            if error != 0 { return nil }
        }

        var name = ""
        if common & attrCmnName != 0 {
            let offset = Int(p.loadUnaligned(as: Int32.self))
            name = String(cString: (p + offset).assumingMemoryBound(to: CChar.self))
            p += 8
        }

        var objType: UInt32 = 0
        if common & attrCmnObjType != 0 {
            objType = p.loadUnaligned(as: UInt32.self)
            p += 4
        }

        var modified: TimeInterval = 0
        if common & attrCmnModTime != 0 {
            let seconds = p.loadUnaligned(as: Int.self)
            let nanos = (p + 8).loadUnaligned(as: Int.self)
            modified = TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000
            p += 16
        }

        var inode: UInt64 = 0
        if common & attrCmnFileID != 0 {
            inode = p.loadUnaligned(as: UInt64.self)
            p += 8
        }

        var linkCount: UInt32 = 1
        if file & attrFileLinkCount != 0 {
            linkCount = p.loadUnaligned(as: UInt32.self)
            p += 4
        }

        var allocated: Int64 = 0
        if file & attrFileAllocSize != 0 {
            allocated = p.loadUnaligned(as: Int64.self)
            p += 8
        }

        var privateSize: Int64?
        if extended, fork & attrCmnExtPrivateSize != 0 {
            privateSize = p.loadUnaligned(as: Int64.self)
            p += 8
        }

        let kind: DirEntry.Kind
        switch objType {
        case vReg: kind = .file
        case vDir: kind = .directory
        case vLnk: kind = .symlink
        default: kind = .other
        }

        if name.isEmpty || name == "." || name == ".." { return nil }
        return DirEntry(name: name, kind: kind, inode: inode, linkCount: linkCount, allocatedSize: allocated, privateSize: privateSize, modified: modified)
    }

    private static func fallbackList(fd: Int32, _ body: (DirEntry) -> Void) -> Bool {
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else {
            if dupFD >= 0 { close(dupFD) }
            return false
        }
        defer { closedir(dir) }
        rewinddir(dir)

        while let raw = readdir(dir) {
            let name = withUnsafeBytes(of: raw.pointee.d_name) { bytes in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            if name == "." || name == ".." { continue }

            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }

            let kind: DirEntry.Kind
            switch st.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            let modified = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
            body(DirEntry(
                name: name,
                kind: kind,
                inode: UInt64(st.st_ino),
                linkCount: UInt32(st.st_nlink),
                allocatedSize: Int64(st.st_blocks) * 512,
                privateSize: nil,
                modified: modified
            ))
        }
        return true
    }
}
