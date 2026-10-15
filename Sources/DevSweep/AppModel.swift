import AppKit
import Foundation
import Observation
import SweepCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview, projects, caches, simulators, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .projects: "Projects"
        case .caches: "Caches"
        case .simulators: "Simulators"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .projects: "folder"
        case .caches: "archivebox"
        case .simulators: "iphone.gen3"
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
    var weeklyScan: Bool { didSet { UserDefaults.standard.set(weeklyScan, forKey: Keys.weeklyScan); Automation.shared.configure(for: self) } }

    private(set) var result: ScanResult? { didSet { rebuildTargets() } }
    private(set) var isScanning = false
    private(set) var scanMessage = ""
    private(set) var scanFraction: Double?
    private(set) var history: [CleanReport] = History.load()
    private(set) var targets: [String: CleanTarget] = [:]

    var selection: Set<String> = []
    var focusedProject: Project.ID?
    var cleanPhase: CleanPhase?

    private enum Keys {
        static let settings = "settings"
        static let weeklyScan = "weeklyScan"
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.settings),
           let saved = try? JSONDecoder().decode(SweepSettings.self, from: data) {
            settings = saved
        } else {
            settings = SweepSettings()
        }
        weeklyScan = UserDefaults.standard.object(forKey: Keys.weeklyScan) as? Bool ?? true
        result = ScanCache.load()
        rebuildTargets()
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
        return "Scanned \(formatter.localizedString(for: result.date, relativeTo: Date()))"
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        scanMessage = "Starting scan…"
        scanFraction = nil
        let scanner = Scanner(settings: settings)
        let fresh = await scanner.scan { progress in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.scanMessage = progress.message
                self.scanFraction = progress.fraction
            }
        }
        result = fresh
        selection = selection.filter { targets[$0] != nil && targets[$0]?.blockedReason == nil }
        if let focusedProject, !fresh.projects.contains(where: { $0.id == focusedProject }) {
            self.focusedProject = nil
        }
        isScanning = false
        scanMessage = ""
        let snapshot = fresh
        Task.detached(priority: .utility) { ScanCache.save(snapshot) }
    }

    // MARK: Targets & selection

    private func rebuildTargets() {
        guard let result else {
            targets = [:]
            return
        }
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
        targets = map
    }

    func id(for artifact: Artifact) -> String { "artifact:\(artifact.path)" }
    func id(for item: CacheItem) -> String { "cache:\(item.id)" }
    func id(for device: SimulatorDevice) -> String { "simulator:\(device.udid)" }
    func id(for runtime: SimulatorRuntime) -> String { "runtime:\(runtime.id)" }

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
        ids += result.caches.filter { $0.tier == .safe }.map(id(for:))
        return ids.filter(isSelectable)
    }

    var recommendedBytes: Int64 {
        recommendedIDs.compactMap { targets[$0]?.bytes }.reduce(0, +)
    }

    func selectRecommended() {
        selection.formUnion(recommendedIDs)
    }

    // MARK: Cleaning

    func reviewSelection() {
        guard !selection.isEmpty else { return }
        cleanPhase = .review
    }

    func clean(mode: DeleteMode) async {
        let targets = selectedTargets
        guard !targets.isEmpty else { return }
        cleanPhase = .running(index: 0, total: targets.count, title: targets[0].title)
        let total = targets.count
        let report = await Cleaner.clean(targets, mode: mode) { index, target in
            Task { @MainActor [weak self] in
                self?.cleanPhase = .running(index: index, total: total, title: target.title)
            }
        }
        cleanPhase = .done(report)
        selection.removeAll()
        history = History.load()
        await scan()
    }

    func emptyFromTrash(_ report: CleanReport) {
        _ = Cleaner.emptyFromTrash(report.trashedPaths)
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
