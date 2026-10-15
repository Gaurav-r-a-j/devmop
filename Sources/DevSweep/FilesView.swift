import AppKit
import SwiftUI
import SweepCore

struct FilesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case large, downloads, duplicates

        var id: String { rawValue }

        var title: String {
            switch self {
            case .large: "Large & Old"
            case .downloads: "Downloads"
            case .duplicates: "Duplicates"
            }
        }
    }

    enum Age: Int, CaseIterable, Identifiable {
        case any = 0, sixMonths = 180, year = 365

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .any: "Any time"
            case .sixMonths: "Not opened in 6 months"
            case .year: "Not opened in a year"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .large
    @State private var age: Age = .any
    @State private var sortOrder = [KeyPathComparator(\UserFile.reclaimable, order: .reverse)]

    private var files: [UserFile] { model.result?.files ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .large: table(large)
            case .downloads: table(files.filter { $0.reasons.contains(where: { $0 != .large && $0 != .duplicate }) })
            case .duplicates: duplicates
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private var large: [UserFile] {
        let cutoff = Date().addingTimeInterval(-Double(age.rawValue) * 24 * 3600)
        return files.filter { file in
            file.reasons.contains(.large) && (age == .any || (file.lastUsed ?? .distantPast) < cutoff)
        }
    }

    private var header: some View {
        let shown: [UserFile] = switch tab {
        case .large: large
        case .downloads: files.filter { $0.reasons.contains(where: { $0 != .large && $0 != .duplicate }) }
        case .duplicates: files.filter { $0.reasons.contains(.duplicate) }
        }
        let bytes = shown.reduce(0) { $0 + $1.reclaimable }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                SectionHeader(title: formatBytes(bytes), subtitle: subtitle(count: shown.count))
                Spacer()
                if tab == .large {
                    Picker("Age", selection: $age) {
                        ForEach(Age.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Label("These are your own files: nothing is selected for you, and they always go to the Trash.", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func subtitle(count: Int) -> String {
        switch tab {
        case .large: "in \(count) files over \(formatBytes(UserFiles.largeThreshold)) in Desktop, Documents, Downloads, Movies, Music and Pictures"
        case .downloads: "in \(count) installers, extracted archives and old downloads"
        case .duplicates: "in \(count) copies of identical files"
        }
    }

    private func table(_ rows: [UserFile]) -> some View {
        Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("") { file in
                checkbox(file)
            }
            .width(22)

            TableColumn("Name", value: \.name) { file in
                FileNameCell(file: file)
            }
            .width(min: 240, ideal: 380)

            TableColumn("Why") { file in
                HStack(spacing: 4) {
                    ForEach(file.reasons, id: \.self) { reason in
                        StatusPill(text: reason.title, symbol: symbol(for: reason), color: color(for: reason))
                    }
                }
            }
            .width(min: 120, ideal: 200)

            TableColumn("Last Opened", value: \.lastUsedSort) { file in
                Text(file.lastOpened.map { relativeDate($0) } ?? file.modified.map { "Modified \(relativeDate($0))" } ?? "Unknown")
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Size", value: \.reclaimable) { file in
                SizeText(bytes: file.reclaimable)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(file.reclaimable < file.allocated ? "Shares space with another copy, so deleting frees \(formatBytes(file.reclaimable)) of \(formatBytes(file.allocated))" : "")
            }
            .width(min: 80, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UserFile.ID.self) { ids in
            if let id = ids.first {
                Button("Show in Finder") { model.revealInFinder(id) }
                Button("Quick Look") { NSWorkspace.shared.open(URL(fileURLWithPath: id)) }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "checkmark.circle", description: Text(emptyText))
            }
        }
    }

    private var emptyText: String {
        switch tab {
        case .large: "No files match. Try a different age filter."
        case .downloads: "Your Downloads folder has no leftover installers, extracted archives or old files."
        case .duplicates: "No duplicate files over 1 MB were found."
        }
    }

    // MARK: Duplicates

    private var duplicateGroups: [[UserFile]] {
        let copies = files.filter { $0.contentHash != nil }
        let grouped = Dictionary(grouping: copies) { $0.contentHash ?? "" }.values
        let sorted = grouped.map { group in group.sorted { $0.path < $1.path } }
        return sorted.sorted { total($0) > total($1) }
    }

    private func total(_ group: [UserFile]) -> Int64 {
        group.reduce(0) { $0 + $1.reclaimable }
    }

    private var duplicates: some View {
        let groups = duplicateGroups
        return List {
            ForEach(groups, id: \.first?.contentHash) { group in
                DuplicateSection(group: group) { file in
                    checkbox(file, group: group)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle", description: Text(emptyText))
            }
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func checkbox(_ file: UserFile, group: [UserFile]? = nil) -> some View {
        let id = model.id(for: file)
        let isSelected = model.isSelected(id)
        let copies = group ?? (file.contentHash.map { hash in files.filter { $0.contentHash == hash } } ?? [])
        let unselectedOthers = copies.filter { $0.id != file.id && !model.isSelected(model.id(for: $0)) }
        let isLastCopy = !copies.isEmpty && !isSelected && unselectedOthers.isEmpty
        TriStateCheckbox(state: isSelected ? .on : .off, isEnabled: model.isSelectable(id) && !isLastCopy) {
            model.setSelected(id, $0)
        }
        .help(isLastCopy ? "The last copy of a duplicate is always kept" : "")
    }

    private func symbol(for reason: UserFileReason) -> String {
        switch reason {
        case .large: "arrow.up.left.and.arrow.down.right"
        case .installer: "shippingbox"
        case .extractedArchive: "archivebox"
        case .oldDownload: "clock"
        case .duplicate: "doc.on.doc"
        }
    }

    private func color(for reason: UserFileReason) -> Color {
        switch reason {
        case .large: .blue
        case .installer: .purple
        case .extractedArchive: .teal
        case .oldDownload: .secondary
        case .duplicate: .orange
        }
    }
}

struct FileNameCell: View {
    let file: UserFile

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text((file.path as NSString).deletingLastPathComponent.abbreviatingHome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

extension UserFile {
    var lastUsedSort: Date { lastUsed ?? .distantPast }
}

struct DuplicateSection<Checkbox: View>: View {
    @Environment(AppModel.self) private var model
    let group: [UserFile]
    let checkbox: (UserFile) -> Checkbox

    var body: some View {
        Section {
            ForEach(group) { file in
                row(file)
            }
        } header: {
            HStack {
                Text(group.first?.name ?? "")
                Text("· \(group.count) copies").foregroundStyle(.secondary)
                Spacer()
                Text("One copy is always kept").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ file: UserFile) -> some View {
        HStack(spacing: 10) {
            checkbox(file)
            FileNameCell(file: file)
            Spacer()
            Text(file.lastOpened.map { relativeDate($0) } ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
            SizeText(bytes: file.reclaimable)
                .frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Show in Finder") { model.revealInFinder(file.path) }
        }
    }
}
