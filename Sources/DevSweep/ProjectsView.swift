import SwiftUI
import SweepCore

enum ProjectFilter: String, CaseIterable, Identifiable {
    case all, inactive, active

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .inactive: "Inactive"
        case .active: "Active"
        }
    }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: ProjectFilter = .all
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\Project.reclaimable, order: .reverse)]
    @State private var showsInspector = true

    private var rows: [Project] {
        guard let projects = model.result?.projects else { return [] }
        let days = model.settings.inactiveDays
        return projects
            .filter { project in
                switch filter {
                case .all: true
                case .inactive: project.isInactive(days: days)
                case .active: !project.isInactive(days: days)
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        @Bindable var model = model
        let rows = rows

        Table(rows, selection: $model.focusedProject, sortOrder: $sortOrder) {
            TableColumn("") { project in
                let ids = model.folderIDs(of: project)
                TriStateCheckbox(state: model.checkState(ids), isEnabled: ids.contains(where: model.isSelectable)) { selected in
                    model.setSelected(ids, selected)
                }
            }
            .width(22)

            TableColumn("Project", value: \.name) { project in
                HStack(spacing: 10) {
                    EcosystemBadge(ecosystem: project.primaryEcosystem)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name).fontWeight(.medium).lineLimit(1)
                        Text(project.path.abbreviatingHome)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Last Active", value: \.lastActiveSort) { project in
                Text(relativeDate(project.lastActive))
                    .foregroundStyle(project.isInactive(days: model.settings.inactiveDays) ? .secondary : .primary)
            }
            .width(min: 100, ideal: 120)

            TableColumn("Status") { project in
                ProjectStatus(project: project, inactiveDays: model.settings.inactiveDays)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Frees", value: \.reclaimable) { project in
                SizeText(bytes: project.reclaimable)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 96)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search projects")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter) {
                    ForEach(ProjectFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem {
                Button {
                    let ids = rows.filter { $0.isInactive(days: model.settings.inactiveDays) && !$0.isInUse }
                        .flatMap { model.folderIDs(of: $0) }
                    model.setSelected(ids, true)
                } label: {
                    Label("Select Inactive", systemImage: "checklist")
                }
                .help("Select build folders of all inactive projects")
            }
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
        .inspector(isPresented: $showsInspector) {
            ProjectInspector(project: model.project(model.focusedProject))
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
    }
}

struct ProjectStatus: View {
    let project: Project
    let inactiveDays: Int

    var body: some View {
        HStack(spacing: 4) {
            if let process = project.runningProcess {
                StatusPill(text: process, symbol: "play.circle.fill", color: .red)
            }
            if let git = project.git {
                if git.isWorktree {
                    StatusPill(text: "Worktree", symbol: "arrow.triangle.branch", color: .purple)
                }
                if git.changedFiles > 0 {
                    StatusPill(text: "\(git.changedFiles)", symbol: "pencil", color: .orange)
                        .help("\(git.changedFiles) uncommitted changes")
                }
                if let unpushed = git.unpushedCommits, unpushed > 0 {
                    StatusPill(text: "\(unpushed)", symbol: "arrow.up", color: .orange)
                        .help("\(unpushed) commits not pushed")
                }
            }
            if project.runningProcess == nil, project.isInactive(days: inactiveDays) {
                StatusPill(text: "Inactive", symbol: "moon.zzz.fill", color: .secondary)
            }
        }
    }
}

struct ProjectInspector: View {
    @Environment(AppModel.self) private var model
    let project: Project?

    var body: some View {
        if let project {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(project)
                    facts(project)
                    folders(project)
                    if let worktree = project.worktreeArtifact {
                        worktreeSection(worktree)
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("No Project Selected", systemImage: "folder", description: Text("Select a project to see its build folders."))
        }
    }

    private func header(_ project: Project) -> some View {
        HStack(spacing: 12) {
            EcosystemBadge(ecosystem: project.primaryEcosystem, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.title3.weight(.semibold)).lineLimit(2)
                Text(project.ecosystems.map(\.title).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.revealInFinder(project.path)
            } label: {
                Image(systemName: "folder")
            }
            .help("Show in Finder")
        }
    }

    private func facts(_ project: Project) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            fact("Location", project.path.abbreviatingHome)
            fact("Last active", relativeDate(project.lastActive))
            if let git = project.git {
                if let branch = git.branch { fact("Branch", branch) }
                fact("Changes", git.changedFiles > 0 ? "\(git.changedFiles) uncommitted" : "None")
                if let unpushed = git.unpushedCommits { fact("Unpushed", unpushed > 0 ? "\(unpushed) commits" : "None") }
            } else {
                fact("Git", "Not a repository")
            }
            fact("Lockfile", project.hasLockfile ? "Yes" : "No")
            if let process = project.runningProcess { fact("In use by", process) }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 12)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func folders(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Build folders").font(.headline)
                Spacer()
                SizeText(bytes: project.reclaimable).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(project.artifactGroups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider() }
                    ArtifactGroupRow(group: group, project: project)
                }
            }
            .card(cornerRadius: 12)
        }
    }

    private func worktreeSection(_ worktree: Artifact) -> some View {
        let id = model.id(for: worktree)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Worktree").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                TriStateCheckbox(state: model.isSelected(id) ? .on : .off, isEnabled: model.isSelectable(id)) {
                    model.setSelected(id, $0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Remove the whole worktree").fontWeight(.medium)
                        Spacer()
                        SizeText(bytes: worktree.size.reclaimable)
                    }
                    Text("Runs git worktree remove. \(worktree.rebuildHint ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let reason = worktree.blockedReason {
                        ReasonLabel(text: reason)
                    } else {
                        Label("Clean, and every commit is in \(model.project(model.focusedProject)?.git?.baseBranch ?? "the base branch")", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(14)
            .card(cornerRadius: 12)
        }
    }
}

struct ArtifactGroupRow: View {
    @Environment(AppModel.self) private var model
    let group: ArtifactGroup
    let project: Project
    @State private var isExpanded = false

    var body: some View {
        let ids = group.artifacts.map(model.id(for:))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                TriStateCheckbox(state: model.checkState(ids), isEnabled: ids.contains(where: model.isSelectable)) {
                    model.setSelected(ids, $0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.folderName).font(.body.monospaced()).fontWeight(.medium)
                        if group.artifacts.count > 1 {
                            Text("×\(group.artifacts.count)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        SizeText(bytes: group.reclaimable)
                    }
                    HStack(spacing: 6) {
                        TierBadge(tier: group.tier)
                        Text(group.name).font(.caption).foregroundStyle(.secondary)
                    }
                    if group.reclaimable < group.allocated / 2 {
                        Text("Uses \(formatBytes(group.allocated)) but most of it is shared, so deleting frees \(formatBytes(group.reclaimable)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = group.blockedReason {
                        ReasonLabel(text: reason)
                    } else if let warning = group.warning {
                        ReasonLabel(text: warning, isBlocking: false)
                    }
                    if let hint = group.rebuildHint {
                        Label(hint, systemImage: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if group.artifacts.count > 1 {
                        DisclosureGroup(isExpanded: $isExpanded) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(group.artifacts) { artifact in
                                    let id = model.id(for: artifact)
                                    HStack(spacing: 8) {
                                        TriStateCheckbox(state: model.isSelected(id) ? .on : .off, isEnabled: model.isSelectable(id)) {
                                            model.setSelected(id, $0)
                                        }
                                        Text(relativePath(artifact.path))
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                        Spacer()
                                        SizeText(bytes: artifact.size.reclaimable).font(.caption)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("\(group.artifacts.count) folders").font(.caption)
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func relativePath(_ path: String) -> String {
        let prefix = project.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
