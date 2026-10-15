import AppKit
import SwiftUI
import SweepCore

/// What makes up one slice of the disk breakdown, opened by clicking it on the Overview or the Storage Map.
struct AreaDetailView: View {
    struct Contributor: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let bytes: Int64
        var selectID: String?
        var revealPath: String?
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: BreakdownItem

    var body: some View {
        let rows = contributors.sorted { $0.bytes > $1.bytes }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(item.color.gradient).frame(width: 18, height: 18)
                    Text(item.title).font(.title2.weight(.semibold))
                    Spacer()
                    Text(formatBytes(item.bytes)).font(.title2.weight(.semibold)).monospacedDigit()
                }
                Label(item.status.title, systemImage: item.status.symbol)
                    .font(.callout)
                    .foregroundStyle(item.status.color)
                if !item.why.isEmpty {
                    Text(item.why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)

            Divider()

            if rows.isEmpty {
                ContentUnavailableView("Nothing to List", systemImage: "square.stack.3d.up.slash",
                                       description: Text("This area isn't made of separate folders DevSweep can list."))
                    .frame(height: 220)
            } else {
                List(rows.prefix(60)) { row in
                    HStack(spacing: 10) {
                        if let id = row.selectID {
                            TriStateCheckbox(state: model.isSelected(id) ? .on : .off, isEnabled: model.isSelectable(id), label: "Select \(row.title)") {
                                model.setSelected(id, $0)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).lineLimit(1).truncationMode(.middle)
                            if let subtitle = row.subtitle {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                        Spacer()
                        SizeText(bytes: row.bytes).fontWeight(.medium)
                        if let path = row.revealPath {
                            Button {
                                model.revealInFinder(path)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .frame(height: 340)
            }

            Divider()

            HStack {
                if rows.contains(where: { $0.selectID != nil }) {
                    Text("Ticked items join your selection. Review & Clean when you're ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let section = item.section {
                    Button(item.actionTitle ?? "Open \(section.title)") {
                        model.section = section
                        dismiss()
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 620)
    }

    private var contributors: [Contributor] {
        guard let result = model.result else { return [] }
        let id = item.id

        if let rules = BreakdownItem.projectRules(for: id) {
            let others = BreakdownItem.assignedProjectRules
            return result.projects.flatMap { project in
                project.artifacts.filter { artifact in
                    artifact.kind == .folder && (rules.isEmpty ? !others.contains(artifact.ruleID) : rules.contains(artifact.ruleID))
                }
                .map { artifact in
                    Contributor(id: artifact.path, title: "\(project.name) › \(artifact.folderName)", subtitle: artifact.path.abbreviatingHome,
                                bytes: artifact.size.reclaimable, selectID: model.id(for: artifact), revealPath: artifact.path)
                }
            }
        }
        if id.hasPrefix("cache-") {
            let group = String(id.dropFirst("cache-".count))
            return caches(result.caches.filter { $0.group.rawValue == group })
        }
        switch id {
        case "docker": return caches(result.caches.filter { $0.group == .docker })
        case "browsers": return caches(result.caches.filter { $0.group == .browsers })
        case "backups": return caches(result.caches.filter { $0.id.hasPrefix("ios-backup:") })
        case "system-other":
            return caches(result.caches.filter { $0.group == .system && !$0.id.hasPrefix("ios-backup:") })
        case "trash": return caches(result.caches.filter { $0.group == .trash })
        case "sim-devices":
            return result.simulators.map {
                Contributor(id: $0.udid, title: "\($0.name) · \($0.runtime)", subtitle: $0.lastBooted.map { "Last booted \(relativeDate($0))" },
                            bytes: $0.size.reclaimable, selectID: model.id(for: $0), revealPath: $0.path)
            }
        case "sim-runtimes":
            return result.runtimes.map {
                Contributor(id: $0.id, title: $0.name, subtitle: $0.lastUsed.map { "Last used \(relativeDate($0))" },
                            bytes: $0.sizeBytes, selectID: model.id(for: $0))
            }
        default:
            break
        }
        if id.hasPrefix("area-"), let slice = result.storage?.first(where: { "area-\($0.kind.rawValue)" == id }) {
            let parts = slice.parts ?? [:]
            return slice.paths.compactMap { path in
                guard let size = parts[path], size.allocated > 0 else { return nil }
                return Contributor(id: path, title: (path as NSString).lastPathComponent, subtitle: path.abbreviatingHome,
                                   bytes: size.allocated, revealPath: path)
            }
        }
        return []
    }

    private func caches(_ items: [CacheItem]) -> [Contributor] {
        items.map {
            Contributor(id: $0.id, title: $0.name, subtitle: $0.paths.first?.abbreviatingHome ?? $0.methodDescription,
                        bytes: $0.size.reclaimable, selectID: model.id(for: $0), revealPath: $0.paths.first)
        }
    }
}
