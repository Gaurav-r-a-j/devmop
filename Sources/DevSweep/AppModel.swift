import AppKit
import Foundation
import Observation
import SweepCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview, projects, caches, simulators, storageMap, systemData, files, apps, trash, history

    static let developer: [SidebarSection] = [.projects, .caches, .simulators]
    static let mac: [SidebarSection] = [.storageMap, .systemData, .files, .apps]
    static let general: [SidebarSection] = [.trash, .history]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .projects: "Projects"
        case .caches: "Caches"
        case .simulators: "Simulators"
        case .storageMap: "Storage Map"
        case .systemData: "System Data"
        case .files: "Files"
        case .apps: "Apps"
        case .trash: "Trash"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .projects: "folder"
        case .caches: "archivebox"
        case .simulators: "iphone.gen3"
        case .storageMap: "chart.bar.doc.horizontal"
        case .systemData: "internaldrive"
        case .files: "doc.on.doc"
        case .apps: "square.grid.2x2"
        case .trash: "trash"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum CheckState { case off, mixed, on }

enum CleanPhase: Equatable {
    case review
    case running(index: Int, total: Int, title: String)
    case done(CleanReport)
}

@Observable
@MainActor
final class AppModel {
    var section: SidebarSection? = .overview
    var settings: SweepSettings { didSet { saveSettings() } }
    var hasSeenWelcome: Bool { didSet { UserDefaults.standard.set(hasSeenWelcome, forKey: Keys.welcome) } }
    var showsMenuBarIcon: Bool { didSet { UserDefaults.standard.set(showsMenuBarIcon, forKey: Keys.menuBar) } }
    var weeklyScan: Bool { didSet { UserDefaults.standard.set(weeklyScan, forKey: Keys.weeklyScan); Automation.shared.configure(for: self) } }

    private(set) var result: ScanResult? { didSet { rebuildTargets() } }
    private(set) var isScanning = false
    private(set) var scanMessage = ""
    private(set) var scanFraction: Double?
    private(set) var history: [CleanReport] = History.load()
    private(set) var targets: [String: CleanTarget] = [:]
    /// The disk breakdown for the current result, computed once per change.
    private(set) var breakdown: [BreakdownItem] = []
    /// Ticks every minute so "Scanned … ago" stays current.
    private(set) var clock = Date()
    @ObservationIgnored private var clockTimer: Timer?

    private(set) var hasFullDiskAccess = SystemInfo.hasFullDiskAccess()
    private var activationObserver: NSObjectProtocol?
    private var dataVersion = 0
    private var rescanRequested = false

    private(set) var trashEntries: [TrashEntry]?
    private(set) var isLoadingTrash = false

    var selection: Set<String> = []
    var focusedProject: Project.ID?
    var cleanPhase: CleanPhase?

    private enum Keys {
        static let settings = "settings"
        static let weeklyScan = "weeklyScan"
        static let menuBar = "showsMenuBarIcon"
        static let welcome = "hasSeenWelcome"
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.settings),
           let saved = try? JSONDecoder().decode(SweepSettings.self, from: data) {
            settings = saved
        } else {
            settings = SweepSettings()
        }
        weeklyScan = UserDefaults.standard.object(forKey: Keys.weeklyScan) as? Bool ?? true
        showsMenuBarIcon = UserDefaults.standard.object(forKey: Keys.menuBar) as? Bool ?? true
        hasSeenWelcome = UserDefaults.standard.bool(forKey: Keys.welcome)
        result = ScanCache.load()
        rebuildTargets()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.clock = Date() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFullDiskAccess() }
        }
    }

    /// Re-checks Full Disk Access live; when it was just granted, rescans so Library folders get measured.
    func refreshFullDiskAccess() {
        let granted = SystemInfo.hasFullDiskAccess()
        let newlyGranted = granted && !hasFullDiskAccess
        hasFullDiskAccess = granted
        if newlyGranted, result != nil {
            Task { await scan() }
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Keys.settings)
        }
    }

    // MARK: Scanning

    var statusText: String {
        if isScanning { return scanMessage.isEmpty ? "Scanning…" : scanMessage }
        guard let result else { return "Not scanned yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Scanned \(formatter.localizedString(for: result.date, relativeTo: max(clock, result.date)))"
    }

    func scan() async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        scanMessage = "Starting scan…"
        scanFraction = nil
        let startVersion = dataVersion
        let scanner = Scanner(settings: settings)
        let fresh = await scanner.scan(previous: result) { progress in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.scanMessage = progress.message
                self.scanFraction = progress.fraction
            }
        }
        isScanning = false
        scanMessage = ""

        // A clean finished while scanning, so these results may list deleted items.
        if startVersion != dataVersion { rescanRequested = true }
        if !rescanRequested {
            result = fresh
            selection = selection.filter { targets[$0] != nil && targets[$0]?.blockedReason == nil }
            if let focusedProject, !fresh.projects.contains(where: { $0.id == focusedProject }) {
                self.focusedProject = nil
            }
            saveCache()
        }
        if weeklyScan { Automation.shared.requestNotificationPermission() }
        if rescanRequested {
            rescanRequested = false
            await scan()
        }
    }

    private func saveCache() {
        guard let snapshot = result else { return }
        Task.detached(priority: .utility) { ScanCache.save(snapshot) }
    }

    // MARK: Targets & selection

    private func rebuildTargets() {
        guard let result else {
            targets = [:]
            breakdown = []
            return
        }
        breakdown = BreakdownItem.breakdown(for: result)
        var map: [String: CleanTarget] = [:]
        for project in result.projects {
            for artifact in project.artifacts {
                let target = CleanTarget.artifact(artifact, project: project)
                map[target.id] = target
            }
        }
        for item in result.caches {
            let target = CleanTarget.cache(item)
            map[target.id] = target
        }
        for device in result.simulators {
            let target = CleanTarget.simulator(device)
            map[target.id] = target
        }
        for runtime in result.runtimes {
            let target = CleanTarget.runtime(runtime)
            map[target.id] = target
        }
        for file in result.files ?? [] {
            let target = CleanTarget.file(file)
            map[target.id] = target
        }
        for app in result.apps ?? [] {
            for target in [CleanTarget.app(app), .appData(app)] { map[target.id] = target }
        }
        for orphan in result.orphans ?? [] {
            let target = CleanTarget.orphan(orphan)
            map[target.id] = target
        }
        targets = map
    }

    func id(for artifact: Artifact) -> String { "artifact:\(artifact.path)" }
    func id(for item: CacheItem) -> String { "cache:\(item.id)" }
    func id(for device: SimulatorDevice) -> String { "simulator:\(device.udid)" }
    func id(for runtime: SimulatorRuntime) -> String { "runtime:\(runtime.id)" }
    func id(for file: UserFile) -> String { "file:\(file.path)" }
    func uninstallID(for app: InstalledApp) -> String { "app:\(app.path)" }
    func dataID(for app: InstalledApp) -> String { "appdata:\(app.path)" }
    func id(for orphan: OrphanedAppData) -> String { "orphan:\(orphan.bundleID)" }

    func isSelectable(_ id: String) -> Bool {
        guard let target = targets[id] else { return false }
        return target.blockedReason == nil && target.bytes > 0
    }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    func setSelected(_ id: String, _ selected: Bool) {
        if selected, isSelectable(id) {
            selection.insert(id)
        } else {
            selection.remove(id)
        }
    }

    func setSelected(_ ids: [String], _ selected: Bool) {
        for id in ids { setSelected(id, selected) }
    }

    func checkState(_ ids: [String]) -> CheckState {
        let selectable = ids.filter(isSelectable)
        guard !selectable.isEmpty else { return .off }
        let count = selectable.filter(selection.contains).count
        if count == 0 { return .off }
        return count == selectable.count ? .on : .mixed
    }

    func folderIDs(of project: Project) -> [String] {
        project.artifacts.filter { $0.kind == .folder }.map(id(for:))
    }

    var selectedTargets: [CleanTarget] {
        selection.compactMap { targets[$0] }.sorted { $0.bytes > $1.bytes }
    }

    /// Selected bytes, skipping folders inside a selected worktree.
    var selectedBytes: Int64 {
        let targets = selectedTargets
        let worktrees = targets.compactMap { target -> String? in
            if case .artifact(let artifact, _) = target, artifact.kind == .worktree { return artifact.path }
            return nil
        }
        return targets.reduce(0) { total, target in
            if case .artifact(let artifact, _) = target, artifact.kind == .folder,
               worktrees.contains(where: { artifact.path.isInside($0) }) {
                return total
            }
            return total + target.bytes
        }
    }

    /// Safe caches plus build folders of inactive projects.
    var recommendedIDs: [String] {
        guard let result else { return [] }
        var ids: [String] = []
        for project in result.projects where project.isInactive(days: settings.inactiveDays) && !project.isInUse {
            ids += project.artifacts
                .filter { $0.kind == .folder && $0.tier <= .rebuildable }
                .map(id(for:))
        }
        ids += result.caches.filter { $0.tier == .safe && $0.group.isDeveloper }.map(id(for:))
        return ids.filter(isSelectable)
    }

    var recommendedBytes: Int64 {
        recommendedIDs.compactMap { targets[$0]?.bytes }.reduce(0, +)
    }

    func selectRecommended() {
        selection = Set(recommendedIDs)
    }

    // MARK: Cleaning

    func reviewSelection() {
        guard !selection.isEmpty else { return }
        cleanPhase = .review
    }

    func clean(mode: DeleteMode) async {
        if case .running = cleanPhase { return }
        let targets = selectedTargets
        guard !targets.isEmpty else { return }
        cleanPhase = .running(index: 0, total: targets.count, title: targets[0].title)
        let total = targets.count
        let report = await Cleaner.clean(targets, mode: mode) { index, target in
            Task { @MainActor [weak self] in
                guard let self, case .running(let shown, _, _) = self.cleanPhase, index >= shown else { return }
                self.cleanPhase = .running(index: index, total: total, title: target.title)
            }
        }
        selection.removeAll()
        applyCleaned(report)
        cleanPhase = .done(report)
        history = History.load()
        await refreshAfterClean(report)
    }

    /// Removes cleaned items from the current results right away.
    private func applyCleaned(_ report: CleanReport) {
        dataVersion += 1
        guard var updated = result else { return }
        let cleaned = Set(report.outcomes.filter(\.succeeded).map(\.targetID))

        updated.projects = updated.projects.compactMap { project in
            if let worktree = project.worktreeArtifact, cleaned.contains(id(for: worktree)) { return nil }
            var project = project
            project.artifacts.removeAll { cleaned.contains(id(for: $0)) }
            return project.artifacts.isEmpty ? nil : project
        }
        for index in updated.caches.indices where cleaned.contains(id(for: updated.caches[index])) {
            updated.caches[index].size = .zero
        }
        updated.caches.removeAll { $0.group == .docker && cleaned.contains(id(for: $0)) }
        updated.simulators.removeAll { cleaned.contains(id(for: $0)) }
        updated.files?.removeAll { cleaned.contains(id(for: $0)) }
        updated.apps?.removeAll { cleaned.contains(uninstallID(for: $0)) }
        if let apps = updated.apps {
            updated.apps = apps.map { app in
                guard cleaned.contains(dataID(for: app)) else { return app }
                var app = app
                app.leftovers.removeAll(where: \.mayHoldUserData)
                return app
            }
        }
        updated.orphans?.removeAll { cleaned.contains(id(for: $0)) }
        updated.runtimes.removeAll { cleaned.contains(id(for: $0)) }
        updated.disk = SystemInfo.disk() ?? updated.disk

        result = updated
        if let focusedProject, !updated.projects.contains(where: { $0.id == focusedProject }) {
            self.focusedProject = nil
        }
        saveCache()
    }

    /// Re-measures cleaned caches and the Trash, since tools like pnpm store prune free only part of a cache.
    private func refreshAfterClean(_ report: CleanReport) async {
        guard let current = result else { return }
        let cleaned = Set(report.outcomes.filter(\.succeeded).map(\.targetID))
        let items = current.caches.filter { $0.group != .docker && $0.group != .trash && cleaned.contains(id(for: $0)) }
        let paths = items.flatMap(\.paths) + [SystemInfo.trashPath]
        let sizes = await DirectorySizer.sizes(of: paths)

        guard var updated = result else { return }
        for index in updated.caches.indices where items.contains(where: { $0.id == updated.caches[index].id }) {
            updated.caches[index].size = updated.caches[index].paths.compactMap { sizes[$0] }.reduce(.zero, +)
        }
        updated.caches.removeAll { $0.group != .trash && $0.size.allocated == 0 }
        Self.setTrash(sizes[SystemInfo.trashPath], in: &updated)
        updated.disk = SystemInfo.disk() ?? updated.disk
        result = updated
        saveCache()
    }

    /// Permanently deletes what this cleanup moved to the Trash; returns bytes freed and items left in place.
    func emptyFromTrash(_ report: CleanReport) async -> (freed: Int64, skipped: Int) {
        let outcome = await Task.detached(priority: .userInitiated) { Cleaner.emptyFromTrash(report) }.value
        let trash = await DirectorySizer.sizes(of: [SystemInfo.trashPath])
        guard var updated = result else { return (outcome.freed, outcome.skipped) }
        Self.setTrash(trash[SystemInfo.trashPath], in: &updated)
        updated.disk = SystemInfo.disk() ?? updated.disk
        result = updated
        saveCache()
        return (outcome.freed, outcome.skipped)
    }

    private static func setTrash(_ size: SizeInfo?, in result: inout ScanResult) {
        guard let size else { return }
        result.trashSize = size.allocated
        if let index = result.caches.firstIndex(where: { $0.id == CacheCatalog.trashID }) {
            result.caches[index].size = size
            if size.allocated == 0 { result.caches.remove(at: index) }
        } else if size.allocated > 0, var item = CacheCatalog.trustedItem(id: CacheCatalog.trashID) {
            item.size = size
            result.caches.append(item)
        }
    }

    // MARK: Trash

    func loadTrash() async {
        guard !isLoadingTrash else { return }
        isLoadingTrash = true
        let entries = await TrashInspector.entries()
        trashEntries = entries
        isLoadingTrash = false
        if let entries, var updated = result {
            let total = entries.reduce(SizeInfo.zero) { $0 + $1.size }
            Self.setTrash(total, in: &updated)
            result = updated
            saveCache()
        }
    }

    func deleteFromTrash(_ entries: [TrashEntry]) async -> CleanReport {
        let report = await Cleaner.deleteFromTrash(entries)
        history = History.load()
        await loadTrash()
        if var updated = result {
            updated.disk = SystemInfo.disk() ?? updated.disk
            result = updated
        }
        return report
    }

    func openTrashInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: SystemInfo.trashPath))
    }

    // MARK: Helpers

    func project(_ id: Project.ID?) -> Project? {
        guard let id else { return nil }
        return result?.projects.first { $0.id == id }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
