import AppKit
import SwiftUI
import SweepCore

struct ProcessesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case servers, leftovers, ai, helpers

        var id: String { rawValue }

        var title: String {
            switch self {
            case .servers: "Dev Servers"
            case .leftovers: "Leftovers & Copies"
            case .ai: "AI & MCP"
            case .helpers: "Editor Helpers"
            }
        }

        func includes(_ process: DevProcess) -> Bool {
            switch self {
            case .servers: [.server, .build, .runtime, .database].contains(process.kind)
            case .leftovers: process.isLeftover || process.copies > 1
            case .ai: process.kind == .ai || process.kind == .mcp
            case .helpers: process.kind == .editorHelper
            }
        }
    }

    private struct PendingStop: Identifiable {
        let id = UUID()
        let processes: [DevProcess]
        let force: Bool
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .servers
    @State private var search = ""
    @State private var portText = ""
    @State private var portMessage: String?
    @State private var pending: PendingStop?
    @State private var banner: String?
    @State private var sortOrder = [KeyPathComparator(\DevProcess.memoryBytes, order: .reverse)]

    private var rows: [DevProcess] {
        model.devProcesses
            .filter { tab.includes($0) }
            .filter { process in
                search.isEmpty || process.displayName.localizedCaseInsensitiveContains(search)
                    || process.commandLine.localizedCaseInsensitiveContains(search)
                    || (process.workingDirectory ?? "").localizedCaseInsensitiveContains(search)
                    || process.ports.contains { String($0) == search }
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner {
                HStack {
                    Label(banner, systemImage: "info.circle")
                    Spacer()
                    Button {
                        self.banner = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            Divider()
            table
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search name, folder or port")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refreshProcesses()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let pending {
                Button(pending.force ? "Force Stop" : "Stop", role: .destructive) { perform(pending) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Unsaved work inside these processes may be lost. Their child processes stop too.")
        }
    }

    // MARK: Header

    private var header: some View {
        let all = model.devProcesses
        let servers = all.filter { !$0.ports.isEmpty && $0.kind != .editorHelper }
        let leftovers = all.filter { $0.isLeftover || $0.copies > 1 }
        return HStack(alignment: .center, spacing: 20) {
            stat("\(servers.count)", "listening on ports", color: .blue)
            stat("\(leftovers.count)", "leftovers & copies", color: leftovers.isEmpty ? .secondary : .orange)
            stat(formatBytes(all.reduce(0) { $0 + $1.memoryBytes }), "memory in use", color: .secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Port, e.g. 3000", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .onSubmit(freePort)
                    Button("Free Port", action: freePort)
                        .disabled(Int(portText) == nil)
                }
                if let portMessage {
                    Text(portMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 320, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if tab == .leftovers, !leftovers.isEmpty {
                Button("Stop All Leftovers…") {
                    pending = PendingStop(processes: leftoversToStop(leftovers), force: false)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func stat(_ value: String, _ label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Leftovers plus all but the newest copy of each duplicated command.
    private func leftoversToStop(_ processes: [DevProcess]) -> [DevProcess] {
        var result = processes.filter(\.isLeftover)
        let duplicated = Dictionary(grouping: processes.filter { $0.copies > 1 && !$0.isLeftover }) { "\($0.commandLine)|\($0.workingDirectory ?? "")" }
        for (_, copies) in duplicated {
            let newestFirst = copies.sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
            result += newestFirst.dropFirst()
        }
        return result
    }

    // MARK: Table

    private var table: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.displayName) { process in
                VStack(alignment: .leading, spacing: 2) {
                    Text(process.displayName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(process.workingDirectory?.abbreviatingHome ?? process.executable.abbreviatingHome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(process.commandLine)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Ports") { process in
                HStack(spacing: 4) {
                    ForEach(process.ports.prefix(3), id: \.self) { port in
                        StatusPill(text: ":\(port)", symbol: "network", color: .blue)
                    }
                }
            }
            .width(min: 70, ideal: 110)

            TableColumn("Status") { process in
                HStack(spacing: 4) {
                    StatusPill(text: process.kind.title, symbol: symbol(for: process.kind), color: .secondary)
                    if process.isLeftover {
                        StatusPill(text: "Leftover", symbol: "exclamationmark.triangle.fill", color: .orange)
                            .help("Still running although the terminal or app that started it is closed.")
                    }
                    if process.copies > 1 {
                        StatusPill(text: "\(process.copies) copies", symbol: "square.on.square", color: .orange)
                    }
                    if let owner = process.ownerApp {
                        Text("from \(owner)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 160, ideal: 260)

            TableColumn("Running", value: \.startedSort) { process in
                Text(process.started.map { relativeDate($0) } ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Memory", value: \.memoryBytes) { process in
                SizeText(bytes: process.memoryBytes).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn("") { process in
                Button("Stop") { pending = PendingStop(processes: [process], force: false) }
                    .controlSize(.small)
            }
            .width(54)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: DevProcess.ID.self) { ids in
            let chosen = model.devProcesses.filter { ids.contains($0.pid) }
            Button("Stop") { pending = PendingStop(processes: chosen, force: false) }
            Button("Force Stop") { pending = PendingStop(processes: chosen, force: true) }
            if let first = chosen.first, first.copies > 1 {
                Button("Stop All \(first.copies) Copies") {
                    let copies = model.devProcesses.filter { $0.commandLine == first.commandLine && $0.workingDirectory == first.workingDirectory }
                    pending = PendingStop(processes: copies, force: false)
                }
            }
            Divider()
            if let folder = chosen.first?.workingDirectory {
                Button("Show Folder in Finder") { model.revealInFinder(folder) }
            }
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chosen.map(\.commandLine).joined(separator: "\n"), forType: .string)
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle", description: Text(emptyDetail))
            }
        }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return "No Matches" }
        return tab == .leftovers ? "No Leftovers" : "Nothing Running"
    }

    private var emptyDetail: String {
        switch tab {
        case .servers: "No dev servers, watchers or databases are running."
        case .leftovers: "Every dev process still belongs to an open terminal or app."
        case .ai: "No model servers or MCP servers are running."
        case .helpers: "No editor language servers are running."
        }
    }

    private func symbol(for kind: DevProcess.Kind) -> String {
        switch kind {
        case .server: "server.rack"
        case .ai: "brain"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .editorHelper: "chevron.left.forwardslash.chevron.right"
        case .database: "cylinder"
        case .build: "arrow.triangle.2.circlepath"
        case .runtime: "terminal"
        }
    }

    // MARK: Actions

    private var confirmTitle: String {
        guard let pending else { return "" }
        let names = pending.processes.prefix(3).map(\.displayName).joined(separator: ", ")
        let more = pending.processes.count > 3 ? " and \(pending.processes.count - 3) more" : ""
        return "\(pending.force ? "Force stop" : "Stop") \(names)\(more)?"
    }

    private func perform(_ request: PendingStop) {
        pending = nil
        Task {
            let outcome = await model.stop(request.processes, force: request.force)
            var parts: [String] = []
            if !outcome.stopped.isEmpty { parts.append("Stopped \(outcome.stopped.count) \(outcome.stopped.count == 1 ? "process" : "processes").") }
            if !outcome.stillRunning.isEmpty { parts.append("\(outcome.stillRunning.count) still running; try Force Stop from the right-click menu.") }
            if !outcome.refused.isEmpty { parts.append(outcome.refused.values.first ?? "") }
            banner = parts.joined(separator: " ")
        }
    }

    private func freePort() {
        guard let port = Int(portText) else { return }
        if let process = model.devProcesses.first(where: { $0.ports.contains(port) }) {
            portMessage = nil
            pending = PendingStop(processes: [process], force: false)
            return
        }
        Task {
            let owner = await Task.detached { DevProcesses.owner(ofPort: port) }.value
            if let owner {
                portMessage = "Port \(port) is used by \(owner.name) (PID \(owner.pid)), which isn't a developer tool, so DevSweep won't stop it."
                    + (owner.name == "ControlCenter" ? " Turn off AirPlay Receiver in System Settings › General › AirDrop & Handoff to free it." : "")
            } else {
                portMessage = "Nothing is listening on port \(port)."
            }
        }
    }
}

extension DevProcess {
    var startedSort: Date { started ?? .distantPast }
}
