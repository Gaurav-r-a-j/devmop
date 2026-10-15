import SwiftUI
import SweepCore

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let result = model.result {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    storage(result)
                    hero(result)
                    notices(result)
                    categories(result)
                    inactiveProjects(result)
                }
                .padding(28)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func storage(_ result: ScanResult) -> some View {
        if let disk = result.disk {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Macintosh HD").font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(formatBytes(disk.available)) available of \(formatBytes(disk.total))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                StorageBar(segments: StorageBar.segments(for: result), total: disk.total)
            }
            .padding(20)
            .card()
        }
    }

    private func hero(_ result: ScanResult) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("You can free up to")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(formatBytes(result.totalReclaimable))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Recommended now: \(formatBytes(model.recommendedBytes)) from safe caches and projects untouched for \(model.settings.inactiveDays)+ days.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    model.selectRecommended()
                    model.reviewSelection()
                } label: {
                    Label("Clean Recommended…", systemImage: "sparkles")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .disabled(model.recommendedBytes == 0)

                Button("Choose Items Myself") { model.section = .projects }
                    .buttonStyle(.link)
            }
        }
        .padding(24)
        .card(cornerRadius: 20)
    }

    @ViewBuilder
    private func notices(_ result: ScanResult) -> some View {
        VStack(spacing: 10) {
            if !result.hasFullDiskAccess {
                Notice(symbol: "lock.shield", color: .orange,
                       title: "Allow Full Disk Access",
                       message: "Some Library folders can't be measured. DevSweep never reads your documents or messages.",
                       actionTitle: "Open Settings") { model.openFullDiskAccessSettings() }
            }
            if result.dockerRunning == false {
                Notice(symbol: "shippingbox", color: .cyan,
                       title: "Docker isn't running",
                       message: "Start Docker Desktop to see how much its images and build cache use.")
            }
            if result.trashSize > 1_000_000_000 {
                Notice(symbol: "trash", color: .gray,
                       title: "\(formatBytes(result.trashSize)) is in the Trash",
                       message: "Empty the Trash in Finder to get this space back.")
            }
        }
    }

    private func categories(_ result: ScanResult) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
            ForEach(Category.allCases) { category in
                Button {
                    switch category {
                    case .projects: model.section = .projects
                    case .caches, .docker: model.section = .caches
                    case .simulators: model.section = .simulators
                    }
                } label: {
                    CategoryCard(category: category, bytes: category.bytes(in: result), detail: detail(for: category, in: result))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detail(for category: Category, in result: ScanResult) -> String {
        switch category {
        case .projects:
            let inactive = result.projects.filter { $0.isInactive(days: model.settings.inactiveDays) }.count
            return "\(result.projects.count) projects · \(inactive) inactive"
        case .caches:
            return "\(result.caches.filter { $0.group != .docker }.count) caches"
        case .simulators:
            return "\(result.simulators.count) devices · \(result.runtimes.count) runtimes"
        case .docker:
            switch result.dockerRunning {
            case .some(true): return "Images and build cache"
            case .some(false): return "Not running"
            case .none: return "Not installed"
            }
        }
    }

    @ViewBuilder
    private func inactiveProjects(_ result: ScanResult) -> some View {
        let stale = result.projects
            .filter { $0.isInactive(days: model.settings.inactiveDays) && $0.reclaimable > 0 }
            .prefix(6)
        if !stale.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Biggest inactive projects").font(.headline)
                    Spacer()
                    Button("Show All") { model.section = .projects }
                        .buttonStyle(.link)
                }
                VStack(spacing: 0) {
                    ForEach(Array(stale.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { Divider().padding(.leading, 52) }
                        Button {
                            model.focusedProject = project.id
                            model.section = .projects
                        } label: {
                            HStack(spacing: 12) {
                                EcosystemBadge(ecosystem: project.primaryEcosystem, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name).fontWeight(.medium)
                                    Text("Last active \(relativeDate(project.lastActive))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                SizeText(bytes: project.reclaimable)
                                    .fontWeight(.medium)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .card(cornerRadius: 14)
            }
        }
    }
}

struct CategoryCard: View {
    let category: Category
    let bytes: Int64
    let detail: String
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                IconTile(symbol: category.symbol, color: category.color, size: 34)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(formatBytes(bytes))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(category.title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .card()
        .scaleEffect(isHovered ? 1.015 : 1)
        .animation(.snappy(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct Notice: View {
    let symbol: String
    let color: Color
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
