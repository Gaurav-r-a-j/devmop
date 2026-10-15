import SwiftUI
import SweepCore

struct CleanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: DeleteMode = .trash
    @State private var emptiedTrash = false
    @State private var isEmptyingTrash = false

    var body: some View {
        Group {
            switch model.cleanPhase {
            case .review, .none: review
            case .running(let index, let total, let title): running(index: index, total: total, title: title)
            case .done(let report): done(report)
            }
        }
        .frame(width: 560)
        .onAppear { mode = model.settings.deleteMode }
    }

    // MARK: Review

    private var review: some View {
        let targets = model.selectedTargets
        let reviewItems = targets.filter { $0.tier == .review }
        let commands = targets.filter { !$0.usesTrash(.trash) }

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clean \(targets.count) \(targets.count == 1 ? "item" : "items")")
                    .font(.title2.weight(.semibold))
                Text("Frees about \(formatBytes(model.selectedBytes))")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(24)

            Divider()

            List {
                ForEach(groups(targets), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.targets) { target in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.title).lineLimit(1).truncationMode(.middle)
                                    if let hint = target.rebuildHint {
                                        Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                TierBadge(tier: target.tier)
                                SizeText(bytes: target.bytes).frame(width: 80, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: 260)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if !reviewItems.isEmpty {
                    Label {
                        Text("\(reviewItems.count) \(reviewItems.count == 1 ? "item needs" : "items need") a second look: \(reviewItems.prefix(3).map(\.title).joined(separator: ", ")). These may hold data you can't download again.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }

                Picker("Delete", selection: $mode) {
                    ForEach(DeleteMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(modeExplanation(commandCount: commands.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: mode == .permanent ? .destructive : nil) {
                    Task { await model.clean(mode: mode) }
                } label: {
                    Text(mode == .trash ? "Move to Trash" : "Delete Permanently").frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .tint(mode == .permanent ? .red : .accentColor)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(20)
        }
    }

    private func modeExplanation(commandCount: Int) -> String {
        var text = mode == .trash
            ? "Folders go to the Trash so you can put them back. They keep using space until the Trash is emptied."
            : "Folders are deleted right away and can't be restored."
        if commandCount > 0 {
            text += " \(commandCount) \(commandCount == 1 ? "item uses its" : "items use their") tool's own clean command (like pnpm store prune or Docker), which always deletes directly."
        }
        return text
    }

    private struct TargetGroup {
        let title: String
        let targets: [CleanTarget]
    }

    private func groups(_ targets: [CleanTarget]) -> [TargetGroup] {
        var projects: [CleanTarget] = []
        var caches: [CleanTarget] = []
        var simulators: [CleanTarget] = []
        for target in targets {
            switch target {
            case .artifact: projects.append(target)
            case .cache: caches.append(target)
            case .simulator, .runtime: simulators.append(target)
            }
        }
        return [
            TargetGroup(title: "Projects", targets: projects),
            TargetGroup(title: "Caches", targets: caches),
            TargetGroup(title: "Simulators", targets: simulators),
        ].filter { !$0.targets.isEmpty }
    }

    // MARK: Running

    private func running(index: Int, total: Int, title: String) -> some View {
        VStack(spacing: 18) {
            ProgressView(value: Double(index), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
            VStack(spacing: 4) {
                Text("Cleaning \(index + 1) of \(total)").font(.headline)
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(32)
        .interactiveDismissDisabled()
    }

    // MARK: Done

    private func done(_ report: CleanReport) -> some View {
        VStack(spacing: 20) {
            Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(report.failures.isEmpty ? .green : .orange)
                .symbolEffect(.bounce, value: report.date)

            VStack(spacing: 6) {
                Text("Cleaned \(formatBytes(report.cleanedBytes))")
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                if report.diskFreedBytes > 0 {
                    Text("Your disk has \(formatBytes(report.diskFreedBytes)) more free space.")
                        .foregroundStyle(.secondary)
                }
            }

            if report.trashedBytes > 0, !emptiedTrash {
                VStack(spacing: 10) {
                    Text("\(formatBytes(report.trashedBytes)) is in the Trash and still uses space.")
                        .foregroundStyle(.secondary)
                    Button {
                        isEmptyingTrash = true
                        Task {
                            await model.emptyFromTrash(report)
                            isEmptyingTrash = false
                            emptiedTrash = true
                        }
                    } label: {
                        if isEmptyingTrash {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Deleting…")
                            }
                        } else {
                            Text("Delete These Items from Trash")
                        }
                    }
                    .disabled(isEmptyingTrash)
                    Text("Only the items DevSweep just moved are removed. Everything else in your Trash stays.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .card(cornerRadius: 12)
            } else if emptiedTrash {
                Label("Removed from the Trash", systemImage: "checkmark")
                    .foregroundStyle(.green)
            }

            if !report.failures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skipped").font(.headline)
                    ForEach(report.failures) { failure in
                        HStack(alignment: .top) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading) {
                                Text(failure.title)
                                Text(failure.message ?? "Failed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.result?.hasLocalSnapshots == true {
                Text("Time Machine keeps local snapshots, so macOS may take a while to show all the freed space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                model.cleanPhase = nil
            } label: {
                Text("Done").frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
    }
}
