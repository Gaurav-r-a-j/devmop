import AppKit
import SwiftUI
import SweepCore

struct TrashView: View {
    @Environment(AppModel.self) private var model
    @State private var checked: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\TrashEntry.size.allocated, order: .reverse)]
    @State private var pendingDelete: [TrashEntry]?
    @State private var lastReport: CleanReport?
    @State private var isDeleting = false

    var body: some View {
        Group {
            if let entries = model.trashEntries {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("Trash Is Empty", systemImage: "trash")
                    } description: {
                        Text(lastReport.map { "Freed \(formatBytes($0.freedBytes))." } ?? "Nothing to clean here.")
                    }
                } else {
                    list(entries)
                }
            } else if model.isLoadingTrash {
                ProgressView("Reading the Trash…")
            } else {
                ContentUnavailableView {
                    Label("DevSweep Can't Open the Trash", systemImage: "lock.shield")
                } description: {
                    Text("macOS only lets apps with Full Disk Access look inside the Trash. Turn DevSweep on in System Settings, then come back.")
                } actions: {
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Open Trash in Finder") { model.openTrashInFinder() }
                }
            }
        }
        .task { await model.loadTrash() }
        .toolbar {
            ToolbarItem {
                Button {
                    model.openTrashInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .help("Open the Trash in Finder")
            }
            ToolbarItem {
                Button {
                    Task { await model.loadTrash() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingTrash)
            }
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                guard let entries = pendingDelete else { return }
                pendingDelete = nil
                Task { await delete(entries) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This can't be undone. Read-only or protected items are left in place.")
        }
    }

    private var confirmTitle: String {
        guard let entries = pendingDelete else { return "" }
        let bytes = entries.reduce(0) { $0 + $1.size.reclaimable }
        return "Delete \(entries.count) \(entries.count == 1 ? "item" : "items") (\(formatBytes(bytes))) from the Trash?"
    }

    private func list(_ entries: [TrashEntry]) -> some View {
        let sorted = entries.sorted(using: sortOrder)
        let total = entries.reduce(0) { $0 + $1.size.reclaimable }
        let selected = entries.filter { checked.contains($0.id) }

        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                IconTile(symbol: "trash.fill", color: .brown, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatBytes(total)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("\(entries.count) \(entries.count == 1 ? "item" : "items") in your Trash")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDeleting {
                    ProgressView().controlSize(.small)
                }
                Button("Delete Selected…") { pendingDelete = selected }
                    .disabled(selected.isEmpty || isDeleting)
                Button(role: .destructive) {
                    pendingDelete = entries
                } label: {
                    Text("Empty Trash…")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isDeleting)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            if let report = lastReport {
                resultBanner(report)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()

            Table(sorted, sortOrder: $sortOrder) {
                TableColumn("") { entry in
                    TriStateCheckbox(state: checked.contains(entry.id) ? .on : .off, label: "Select \(entry.name)") { isOn in
                        if isOn { checked.insert(entry.id) } else { checked.remove(entry.id) }
                    }
                }
                .width(22)

                TableColumn("Name", value: \.name) { entry in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(entry.name).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 220, ideal: 360)

                TableColumn("Deleted", value: \.dateSort) { entry in
                    Text(entry.dateAdded.map { relativeDate($0) } ?? "Unknown")
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 140)

                TableColumn("Size", value: \.size.allocated) { entry in
                    SizeText(bytes: entry.size.reclaimable)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 100)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: TrashEntry.ID.self) { ids in
                Button("Show in Finder") {
                    if let id = ids.first { model.revealInFinder(id) }
                }
                Button("Delete Permanently…", role: .destructive) {
                    pendingDelete = entries.filter { ids.contains($0.id) }
                }
            }
        }
    }

    private func resultBanner(_ report: CleanReport) -> some View {
        let skipped = report.outcomes.reduce(0) { $0 + ($1.skippedItems ?? 0) }
        return HStack(spacing: 10) {
            Image(systemName: skipped == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(skipped == 0 ? .green : .orange)
            Text("Freed \(formatBytes(report.freedBytes))")
                .fontWeight(.medium)
            if skipped > 0 {
                Text("· \(skipped) read-only or protected \(skipped == 1 ? "item was" : "items were") left in place")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                lastReport = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func delete(_ entries: [TrashEntry]) async {
        isDeleting = true
        lastReport = await model.deleteFromTrash(entries)
        checked.subtract(entries.map(\.id))
        isDeleting = false
    }
}

extension TrashEntry {
    var dateSort: Date { dateAdded ?? .distantPast }
}
