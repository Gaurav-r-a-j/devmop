import AppKit
import SwiftUI
import SweepCore

struct AppsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case installed, leftovers

        var id: String { rawValue }
        var title: String { self == .installed ? "Installed Apps" : "Leftovers of Deleted Apps" }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .installed
    @State private var focused: InstalledApp.ID?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\InstalledApp.totalReclaimable, order: .reverse)]
    @State private var showsInspector = true

    private var apps: [InstalledApp] {
        (model.result?.apps ?? [])
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            switch tab {
            case .installed: installed
            case .leftovers: leftovers
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if tab == .installed {
                ToolbarItem {
                    Button {
                        showsInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                }
            }
        }
    }

    // MARK: Installed

    private var installed: some View {
        Table(apps, selection: $focused, sortOrder: $sortOrder) {
            TableColumn("") { app in
                let id = model.uninstallID(for: app)
                TriStateCheckbox(state: model.isSelected(id) ? .on : .off, isEnabled: model.isSelectable(id), label: "Uninstall \(app.name)") {
                    model.setSelected(id, $0)
                }
                .help("Uninstall \(app.name)")
            }
            .width(22)

            TableColumn("App", value: \.name) { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).fontWeight(.medium).lineLimit(1)
                        Text([app.version.map { "Version \($0)" }, app.isAppStore ? "App Store" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 220, ideal: 300)

            TableColumn("Last Used", value: \.lastUsedSort) { app in
                Text(app.lastUsed.map { relativeDate($0) } ?? "Never")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)

            TableColumn("Status") { app in
                HStack(spacing: 4) {
                    if app.blockedReason != nil {
                        StatusPill(text: "Running", symbol: "play.circle.fill", color: .green)
                    }
                    if !app.leftovers.isEmpty {
                        StatusPill(text: "\(app.leftovers.count) leftovers", symbol: "tray.full", color: .secondary)
                    }
                    if app.systemPartsWarning != nil {
                        StatusPill(text: "System parts", symbol: "exclamationmark.triangle", color: .orange)
                    }
                }
            }
            .width(min: 120, ideal: 200)

            TableColumn("Size", value: \.totalReclaimable) { app in
                SizeText(bytes: app.totalReclaimable)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 96)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .inspector(isPresented: $showsInspector) {
            AppInspector(app: apps.first { $0.id == focused } ?? model.result?.apps?.first { $0.id == focused })
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .overlay {
            if apps.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No Apps Found", systemImage: "square.grid.2x2",
                                           description: Text(model.result?.apps == nil ? "Scan again to list your apps." : "No third-party apps are installed."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }

    // MARK: Leftovers

    private var leftovers: some View {
        let orphans = (model.result?.orphans ?? []).filter { search.isEmpty || $0.bundleID.localizedCaseInsensitiveContains(search) }
        return List {
            Section {
                Label("Data left behind by apps that are no longer installed. Only folders named after an app's ID are listed, and nothing is selected for you.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(orphans) { orphan in
                OrphanRow(orphan: orphan)
            }
        }
        .listStyle(.inset)
        .overlay {
            if orphans.isEmpty {
                ContentUnavailableView("No Leftovers", systemImage: "checkmark.circle", description: Text("No data from deleted apps was found."))
            }
        }
    }
}

struct AppInspector: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp?

    var body: some View {
        if let app {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.title3.weight(.semibold))
                            Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            model.revealInFinder(app.path)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Show in Finder")
                    }

                    if let reason = app.blockedReason {
                        ReasonLabel(text: reason)
                    }
                    if let warning = app.systemPartsWarning {
                        ReasonLabel(text: warning, isBlocking: false)
                    }

                    option(
                        id: model.uninstallID(for: app),
                        title: "Uninstall the app",
                        detail: "Moves the app and its caches, settings, logs and window state to the Trash.",
                        bytes: app.uninstallBytes,
                        items: [AppLeftover(path: app.path, kind: "App", size: app.size)] + app.supportLeftovers
                    )

                    if !app.dataLeftovers.isEmpty {
                        option(
                            id: model.dataID(for: app),
                            title: "Also remove its data",
                            detail: "App data and containers can hold your documents, notes or projects. Only tick this if you don't need them.",
                            bytes: app.dataBytes,
                            items: app.dataLeftovers
                        )
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("No App Selected", systemImage: "square.grid.2x2", description: Text("Select an app to see what removing it would delete."))
        }
    }

    private func option(id: String, title: String, detail: String, bytes: Int64, items: [AppLeftover]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                TriStateCheckbox(state: model.isSelected(id) ? .on : .off, isEnabled: model.isSelectable(id), label: title) {
                    model.setSelected(id, $0)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title).fontWeight(.medium)
                        Spacer()
                        SizeText(bytes: bytes)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Text(item.kind).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(item.path.abbreviatingHome)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        SizeText(bytes: item.size.reclaimable).font(.caption)
                    }
                }
            }
            .padding(.leading, 30)
        }
        .padding(14)
        .card(cornerRadius: 12)
    }
}

struct OrphanRow: View {
    @Environment(AppModel.self) private var model
    let orphan: OrphanedAppData
    @State private var isExpanded = false

    var body: some View {
        let id = model.id(for: orphan)
        HStack(alignment: .top, spacing: 10) {
            TriStateCheckbox(state: model.isSelected(id) ? .on : .off, isEnabled: model.isSelectable(id), label: "Select leftovers of \(orphan.name)") {
                model.setSelected(id, $0)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(orphan.name.capitalized).fontWeight(.medium)
                    Text(orphan.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    SizeText(bytes: orphan.reclaimable).fontWeight(.medium)
                }
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(orphan.leftovers) { leftover in
                            HStack {
                                Text(leftover.kind).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                                Text(leftover.path.abbreviatingHome).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                                Spacer()
                                SizeText(bytes: leftover.size.reclaimable).font(.caption)
                            }
                        }
                    }
                } label: {
                    Text("\(orphan.leftovers.count) \(orphan.leftovers.count == 1 ? "folder" : "folders")").font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension InstalledApp {
    var lastUsedSort: Date { lastUsed ?? .distantPast }
}
