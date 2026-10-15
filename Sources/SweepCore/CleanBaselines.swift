import Foundation

/// Size right after a tool's own clean, so later scans count only what was added since (e.g. the pnpm store).
public enum CleanBaselines {
    public struct Baseline: Codable, Hashable, Sendable {
        public let bytes: Int64
        public let date: Date
    }

    static var file: URL { History.directory.appendingPathComponent("baselines.json") }
    private static let lock = NSLock()

    public static func load() -> [String: Baseline] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Baseline].self, from: data)) ?? [:]
    }

    static func record(_ id: String, bytes: Int64, date: Date = Date()) {
        var baselines = load()
        baselines[id] = Baseline(bytes: bytes, date: date)
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: History.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(baselines) { try? data.write(to: file, options: .atomic) }
    }

    /// The item with its reclaimable size reduced to what was added since its last clean.
    public static func adjusted(_ item: CacheItem, baselines: [String: Baseline] = load()) -> CacheItem {
        guard case .command = item.method, let baseline = baselines[item.id], !item.paths.isEmpty else { return item }
        var item = item
        if item.size.allocated < baseline.bytes {
            record(item.id, bytes: item.size.allocated)
            item.size.reclaimable = 0
        } else {
            item.size.reclaimable = item.size.allocated - baseline.bytes
        }
        item.size.isEstimate = true
        item.lastCleaned = baseline.date
        return item
    }
}
