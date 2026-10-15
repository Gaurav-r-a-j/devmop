import AppKit
import SwiftUI
import SweepCore

@main
struct DevSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("DevSweep", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
                .task { Automation.shared.configure(for: model) }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan Now") { Task { await model.scan() } }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Button("Select Recommended") { model.selectRecommended() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.result == nil)
                Divider()
                Button("Review & Clean…") { model.reviewSelection() }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(model.selection.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Binding(get: { model.showsMenuBarIcon }, set: { model.showsMenuBarIcon = $0 })) {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: "sparkles.rectangle.stack")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                if model.result == nil {
                    FirstRunView()
                } else {
                    switch model.section ?? .overview {
                    case .overview: OverviewView()
                    case .projects: ProjectsView()
                    case .caches: CachesView(scope: .developer)
                    case .storageMap: StorageMapView()
                    case .systemData: CachesView(scope: .system)
                    case .files: FilesView()
                    case .apps: AppsView()
                    case .simulators: SimulatorsView()
                    case .trash: TrashView()
                    case .history: HistoryView()
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !model.selection.isEmpty {
                    SelectionBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.selection.isEmpty)
        }
        .navigationTitle(model.section?.title ?? "DevSweep")
        .navigationSubtitle(model.statusText)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 6)
                } else {
                    Button {
                        Task { await model.scan() }
                    } label: {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                    .help("Scan again (⌘R)")
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { !model.hasSeenWelcome && model.cleanPhase == nil },
            set: { if !$0 { model.hasSeenWelcome = true } }
        )) {
            WelcomeView()
                .environment(model)
        }
        .sheet(isPresented: Binding(
            get: { model.cleanPhase != nil },
            set: { if !$0 { model.cleanPhase = nil } }
        )) {
            CleanSheet()
                .environment(model)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.section) {
            Label(SidebarSection.overview.title, systemImage: SidebarSection.overview.symbol)
                .tag(SidebarSection.overview)
            Section("Developer") { rows(SidebarSection.developer) }
            Section("Mac") { rows(SidebarSection.mac) }
            Section { rows(SidebarSection.general) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let disk = model.result?.disk {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "internaldrive")
                        Text(disk.displayName).font(.caption.weight(.medium))
                    }
                    ProgressView(value: Double(disk.used), total: Double(max(disk.total, 1)))
                        .tint(Double(disk.available) / Double(max(disk.total, 1)) < 0.1 ? .red : .accentColor)
                    Text("\(formatBytes(disk.available)) available of \(formatBytes(disk.total))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
    }

    private func rows(_ sections: [SidebarSection]) -> some View {
        ForEach(sections) { section in
            Label(section.title, systemImage: section.symbol)
                .badge(badge(for: section))
                .tag(section)
        }
    }

    private func badge(for section: SidebarSection) -> Text? {
        guard let result = model.result else { return nil }
        let bytes: Int64
        switch section {
        case .projects: bytes = result.projectBytes
        case .caches: bytes = result.cacheBytes + result.dockerBytes
        case .simulators: bytes = result.simulatorBytes
        case .trash: bytes = result.trashBytes
        case .systemData: bytes = result.systemBytes
        case .files, .apps, .storageMap: return nil
        case .overview, .history: return nil
        }
        return bytes > 0 ? Text(formatBytes(bytes)) : nil
    }
}

struct SelectionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.selection.count) \(model.selection.count == 1 ? "item" : "items") selected")
                    .font(.headline)
                Text("Frees about \(formatBytes(model.selectedBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Clear") { model.selection.removeAll() }
                .controlSize(.large)
            Button {
                model.reviewSelection()
            } label: {
                Text("Review & Clean…").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct FirstRunView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: model.isScanning)
            VStack(spacing: 6) {
                Text(model.isScanning ? "Scanning your Mac…" : "Find the space your dev tools waste")
                    .font(.title.weight(.semibold))
                Text(model.isScanning
                     ? model.scanMessage
                     : "DevSweep looks for build folders, package caches, simulators and Docker data, and shows what is safe to remove.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if model.isScanning {
                if let fraction = model.scanFraction {
                    ProgressView(value: fraction).frame(width: 280)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Button {
                    Task { await model.scan() }
                } label: {
                    Text("Scan My Mac").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                Text("Nothing is deleted until you review and confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("DevSweep").font(.headline)
                Spacer()
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let result = model.result {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatBytes(result.totalReclaimable))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("can be freed")
                        .foregroundStyle(.secondary)
                }
                if let disk = result.disk {
                    StorageBar(segments: StorageBar.segments(model.breakdown), total: disk.total, height: 10, showsLegend: false)
                    Text("\(formatBytes(disk.available)) available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(model.isScanning ? "Scanning…" : "Scan Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
                Spacer()
                Button("Open DevSweep") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Quit DevSweep") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(16)
        .frame(width: 300)
    }
}
