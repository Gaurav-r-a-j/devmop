import AppKit
import SwiftUI
import SweepCore

struct StorageMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let result = model.result, let disk = result.disk {
            let items = BreakdownItem.breakdown(for: result)
            let largest = items.map(\.bytes).max() ?? 1

            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "\(formatBytes(disk.used)) used",
                                      subtitle: "Every part of your disk, what it is, and whether DevSweep can clean it.")
                        StorageBar(segments: StorageBar.segments(for: result), total: disk.total, height: 22, showsLegend: false)
                        HStack(spacing: 14) {
                            ForEach([AreaStatus.cleanable, .partly, .yourData, .managed, .readOnly], id: \.self) { status in
                                Label(status.title, systemImage: status.symbol)
                                    .font(.caption)
                                    .foregroundStyle(status.color)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                ForEach(BreakdownItem.Group.allCases, id: \.self) { group in
                    let rows = items.filter { $0.group == group }.sorted { $0.bytes > $1.bytes }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { item in
                                AreaRow(item: item, largest: largest)
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                Spacer()
                                Text(formatBytes(rows.reduce(0) { $0 + $1.bytes })).monospacedDigit()
                            }
                        }
                    }
                }

                if !model.hasFullDiskAccess {
                    Section {
                        ReasonLabel(text: "Some folders, like Pictures, Mail and parts of Library, can only be measured with Full Disk Access.", isBlocking: false)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct AreaRow: View {
    @Environment(AppModel.self) private var model
    let item: BreakdownItem
    let largest: Int64

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(item.color.gradient)
                .frame(width: 14, height: 14)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).fontWeight(.medium)
                    Label(item.status.title, systemImage: item.status.symbol)
                        .font(.caption)
                        .foregroundStyle(item.status.color)
                    Spacer()
                    Text(formatBytes(item.bytes)).fontWeight(.semibold).monospacedDigit()
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(item.color.opacity(0.85))
                        .frame(width: max(3, proxy.size.width * CGFloat(Double(item.bytes) / Double(max(largest, 1)))))
                }
                .frame(height: 5)
                if !item.why.isEmpty {
                    Text(item.why)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    if let section = item.section {
                        Button(item.actionTitle ?? "Open \(section.title)") { model.section = section }
                    }
                    if let path = item.revealPath {
                        Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}
