import CoreServices
import Darwin
import Foundation

/// Reads the macOS FSEvents log to learn which folders changed since a past scan.
public enum ChangeJournal {
    public struct Mark: Codable, Hashable, Sendable {
        public let eventID: UInt64
        public let volume: String
        public let date: Date
    }

    /// The point in the change log to resume from next time.
    public static func currentMark(for path: String = NSHomeDirectory()) -> Mark? {
        guard let volume = volumeID(for: path) else { return nil }
        return Mark(eventID: FSEventsGetCurrentEventId(), volume: volume, date: Date())
    }

    /// Folders changed under `roots` since `mark`, or nil when the log can't be trusted and everything must be measured.
    public static func changes(since mark: Mark?, under roots: [String], maxAge: TimeInterval = 7 * 24 * 3600, timeout: TimeInterval = 20) -> [String]? {
        guard let mark, !roots.isEmpty,
              Date().timeIntervalSince(mark.date) < maxAge,
              volumeID(for: roots[0]) == mark.volume
        else { return nil }

        let collector = Collector()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            collector.receive(count: count, paths: paths, flags: eventFlags)
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray, mark.eventID, 0, flags) else { return nil }
        let queue = DispatchQueue(label: "app.devmop.fsevents")
        FSEventStreamSetDispatchQueue(stream, queue)
        defer {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        guard FSEventStreamStart(stream) else { return nil }

        let finished = collector.done.wait(timeout: .now() + timeout) == .success
        return queue.sync {
            finished && collector.complete && !collector.mustRescan ? collector.paths : nil
        }
    }

    /// Changed folders, indexed so "did anything inside this path change?" is a binary search.
    public struct ChangeSet: Sendable {
        private let sorted: [String]
        private let exact: Set<String>

        public init(_ paths: [String]) {
            exact = Set(paths)
            sorted = exact.sorted()
        }

        public var count: Int { sorted.count }

        public func touches(_ path: String) -> Bool {
            if exact.contains(path) { return true }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            var low = 0
            var high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid] < prefix { low = mid + 1 } else { high = mid }
            }
            return low < sorted.count && sorted[low].hasPrefix(prefix)
        }
    }

    private final class Collector: @unchecked Sendable {
        var paths: [String] = []
        var complete = false
        var mustRescan = false
        let done = DispatchSemaphore(value: 0)

        private static let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
            | UInt32(kFSEventStreamEventFlagUserDropped)
            | UInt32(kFSEventStreamEventFlagKernelDropped)
            | UInt32(kFSEventStreamEventFlagEventIdsWrapped)
            | UInt32(kFSEventStreamEventFlagRootChanged)
            | UInt32(kFSEventStreamEventFlagMount)
            | UInt32(kFSEventStreamEventFlagUnmount)

        func receive(count: Int, paths eventPaths: UnsafePointer<UnsafePointer<CChar>>, flags: UnsafePointer<FSEventStreamEventFlags>) {
            for index in 0..<count {
                let flag = flags[index]
                if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    if !complete {
                        complete = true
                        done.signal()
                    }
                    continue
                }
                if flag & Self.rescanFlags != 0 { mustRescan = true }
                var path = String(cString: eventPaths[index])
                if path.count > 1, path.hasSuffix("/") { path.removeLast() }
                paths.append(path)
            }
        }
    }

    private static func volumeID(for path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
