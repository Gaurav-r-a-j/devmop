import SwiftUI
import SweepCore

struct CachesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let result = model.result {
            let groups = CacheGroup.allCases.compactMap { group -> (CacheGroup, [CacheItem])? in
                let items = result.caches.filter { $0.group == group }.sorted { $0.size.reclaimable > $1.size.reclaimable }
                return items.isEmpty && group != .docker ? nil : (group, items)
            }

            List {
                Section {
                    HStack(alignment: .center) {
                        SectionHeader(
                            title: formatBytes(result.cacheBytes + result.dockerBytes),
                            subtitle: "in caches that tools download or rebuild on demand"
                        )
                        Spacer()
                        Button("Select All Safe") {
                            model.setSelected(result.caches.filter { $0.tier == .safe }.map(model.id(for:)), true)
                        }
                    }
                    .padding(.vertical, 8)
                }

                ForEach(groups, id: \.0) { group, items in
                    Section {
                        if group == .docker, items.isEmpty {
                            dockerStatus(result.dockerRunning)
                        }
                        ForEach(items) { item in
                            CacheRow(item: item)
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            let ids = items.map(model.id(for:))
                            if ids.contains(where: model.isSelectable) {
                                TriStateCheckbox(state: model.checkState(ids)) { model.setSelected(ids, $0) }
                                    .help("Select all in \(group.title)")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func dockerStatus(_ running: Bool?) -> some View {
        switch running {
        case .some(false):
            ReasonLabel(text: "Docker isn't running. Start Docker Desktop and scan again.", isBlocking: false)
                .padding(.vertical, 6)
        case .none:
            ReasonLabel(text: "Docker isn't installed.")
                .padding(.vertical, 6)
        case .some(true):
            Text("Nothing to clean").foregroundStyle(.secondary).padding(.vertical, 6)
        }
    }
}

struct CacheRow: View {
    @Environment(AppModel.self) private var model
    let item: CacheItem

    var body: some View {
        let id = model.id(for: item)
        HStack(alignment: .center, spacing: 12) {
            TriStateCheckbox(state: model.isSelected(id) ? .on : .off, isEnabled: model.isSelectable(id)) {
                model.setSelected(id, $0)
            }
            IconTile(symbol: item.symbol, color: item.group.color, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name).fontWeight(.medium)
                    TierBadge(tier: item.tier)
                }
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Label(item.methodDescription, systemImage: methodSymbol)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if let reason = item.blockedReason {
                        ReasonLabel(text: reason)
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                SizeText(bytes: item.size.reclaimable, isEstimate: item.size.isEstimate)
                    .fontWeight(.medium)
                if let path = item.paths.first {
                    Button {
                        model.revealInFinder(path)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(item.blockedReason == nil ? 1 : 0.7)
    }

    private var methodSymbol: String {
        if case .command = item.effectiveMethod { return "terminal" }
        return "trash"
    }
}

struct SimulatorsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let result = model.result {
            List {
                Section {
                    HStack {
                        SectionHeader(title: formatBytes(result.simulatorBytes), subtitle: "in simulator devices and runtimes")
                        Spacer()
                        Button("Select Unused for 30 Days") {
                            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
                            let ids = result.simulators.filter { ($0.lastBooted ?? .distantPast) < cutoff }.map(model.id(for:))
                            model.setSelected(ids, true)
                        }
                    }
                    .padding(.vertical, 8)
                }

                if !result.runtimes.isEmpty {
                    Section("Runtimes") {
                        ForEach(result.runtimes) { runtime in
                            let id = model.id(for: runtime)
                            HStack(spacing: 12) {
                                TriStateCheckbox(state: model.isSelected(id) ? .on : .off, isEnabled: model.isSelectable(id)) {
                                    model.setSelected(id, $0)
                                }
                                IconTile(symbol: "cpu", color: .orange, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(runtime.name).fontWeight(.medium)
                                    Text("Last used \(relativeDate(runtime.lastUsed))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !runtime.isDeletable { ReasonLabel(text: "Managed by macOS") }
                                }
                                Spacer()
                                SizeText(bytes: runtime.sizeBytes).fontWeight(.medium)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Devices") {
                    ForEach(result.simulators) { device in
                        let id = model.id(for: device)
                        HStack(spacing: 12) {
                            TriStateCheckbox(state: model.isSelected(id) ? .on : .off, isEnabled: model.isSelectable(id)) {
                                model.setSelected(id, $0)
                            }
                            IconTile(symbol: device.name.contains("iPad") ? "ipad" : device.name.contains("Watch") ? "applewatch" : "iphone", color: .orange.opacity(0.85), size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(device.name).fontWeight(.medium)
                                    Text(device.runtime).foregroundStyle(.secondary)
                                    if device.isBooted {
                                        StatusPill(text: "Running", symbol: "play.circle.fill", color: .green)
                                    }
                                    if !device.isAvailable {
                                        StatusPill(text: "Unavailable", symbol: "xmark.circle", color: .secondary)
                                    }
                                }
                                Text(device.lastBooted.map { "Last booted \(relativeDate($0))" } ?? "Never booted")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            SizeText(bytes: device.size.reclaimable).fontWeight(.medium)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if result.simulators.isEmpty && result.runtimes.isEmpty {
                    ContentUnavailableView("No Simulators", systemImage: "iphone.gen3.slash", description: Text("Xcode simulators will appear here."))
                }
            }
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.history) { report in
                HistoryRow(report: report)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.history.isEmpty {
                ContentUnavailableView("No Cleanups Yet", systemImage: "clock.arrow.circlepath", description: Text("Every cleanup is recorded here with how to rebuild what was removed."))
            }
        }
    }
}

struct HistoryRow: View {
    let report: CleanReport
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.outcomes) { outcome in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(outcome.succeeded ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outcome.title)
                            if let message = outcome.message {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                            if outcome.succeeded, let hint = outcome.rebuildHint {
                                Label(hint, systemImage: "arrow.uturn.backward")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        SizeText(bytes: outcome.bytes).font(.callout)
                    }
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack {
                IconTile(symbol: report.mode == .trash ? "trash" : "flame", color: report.failures.isEmpty ? .green : .orange, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.date.formatted(date: .abbreviated, time: .shortened)).fontWeight(.medium)
                    Text("\(report.outcomes.count) items · \(report.mode.title)\(report.failures.isEmpty ? "" : " · \(report.failures.count) failed")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SizeText(bytes: report.cleanedBytes).fontWeight(.semibold)
            }
            .padding(.vertical, 4)
        }
    }
}
