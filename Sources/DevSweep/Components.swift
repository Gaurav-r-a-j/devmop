import AppKit
import SwiftUI
import SweepCore

extension SafetyTier {
    var color: Color {
        switch self {
        case .safe: .green
        case .rebuildable: .blue
        case .review: .orange
        case .protected: .gray
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .rebuildable: "arrow.triangle.2.circlepath"
        case .review: "exclamationmark.triangle.fill"
        case .protected: "lock.fill"
        }
    }
}

extension Ecosystem {
    var monogram: String {
        switch self {
        case .node: "JS"
        case .python: "Py"
        case .rust: "Rs"
        case .swift: "Sw"
        case .apple: "Xc"
        case .gradle: "Gr"
        case .go: "Go"
        case .dart: "Fl"
        case .ruby: "Rb"
        case .php: "Ph"
        case .java: "Jv"
        case .elixir: "Ex"
        case .dotnet: ".N"
        case .terraform: "Tf"
        }
    }

    var color: Color {
        switch self {
        case .node: Color(red: 0.35, green: 0.65, blue: 0.25)
        case .python: Color(red: 0.22, green: 0.45, blue: 0.68)
        case .rust: Color(red: 0.80, green: 0.36, blue: 0.20)
        case .swift: Color(red: 0.95, green: 0.42, blue: 0.20)
        case .apple: Color(red: 0.16, green: 0.50, blue: 0.95)
        case .gradle: Color(red: 0.10, green: 0.55, blue: 0.50)
        case .go: Color(red: 0.0, green: 0.66, blue: 0.80)
        case .dart: Color(red: 0.02, green: 0.60, blue: 0.85)
        case .ruby: Color(red: 0.75, green: 0.15, blue: 0.20)
        case .php: Color(red: 0.47, green: 0.48, blue: 0.70)
        case .java: Color(red: 0.85, green: 0.45, blue: 0.10)
        case .elixir: Color(red: 0.42, green: 0.27, blue: 0.55)
        case .dotnet: Color(red: 0.36, green: 0.18, blue: 0.57)
        case .terraform: Color(red: 0.48, green: 0.26, blue: 0.85)
        }
    }
}

extension CacheGroup {
    var color: Color {
        switch self {
        case .packageManagers: .purple
        case .apple: .blue
        case .languages: .teal
        case .editors: .indigo
        case .testing: .pink
        case .docker: .cyan
        case .trash: .brown
        case .system: .gray
        case .browsers: .orange
        }
    }
}

extension Project {
    var lastActiveSort: Date { lastActive ?? .distantPast }
    var primaryEcosystem: Ecosystem? { ecosystems.first }
}

enum Category: String, CaseIterable, Identifiable {
    case projects, caches, system, simulators, docker, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Project build files"
        case .caches: "Developer caches"
        case .system: "System data"
        case .simulators: "Simulators"
        case .docker: "Docker"
        case .trash: "Trash"
        }
    }

    var color: Color {
        switch self {
        case .projects: .blue
        case .caches: .purple
        case .system: .gray
        case .simulators: .orange
        case .docker: .cyan
        case .trash: .brown
        }
    }

    var symbol: String {
        switch self {
        case .projects: "folder.fill"
        case .caches: "archivebox.fill"
        case .system: "internaldrive.fill"
        case .simulators: "iphone.gen3"
        case .docker: "shippingbox.fill"
        case .trash: "trash.fill"
        }
    }

    var section: SidebarSection {
        switch self {
        case .projects: .projects
        case .caches, .docker: .caches
        case .system: .systemData
        case .trash: .trash
        case .simulators: .simulators
        }
    }

    func bytes(in result: ScanResult) -> Int64 {
        switch self {
        case .projects: result.projectBytes
        case .caches: result.cacheBytes
        case .system: result.systemBytes
        case .simulators: result.simulatorBytes
        case .docker: result.dockerBytes
        case .trash: result.trashBytes
        }
    }
}

/// One coloured slice of the disk breakdown on the Overview.
struct BreakdownItem: Identifiable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
    let section: SidebarSection?

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    private static let projectKinds: [(id: String, title: String, color: Color, rules: Set<String>)] = [
        ("node-modules", "node_modules", rgb(10, 132, 255), ["node-modules"]),
        ("framework-builds", "Framework builds (.next, dist…)", rgb(94, 92, 230),
         ["next", "nuxt", "nuxt-output", "svelte-kit", "astro", "docusaurus", "expo", "storybook", "node-dist", "node-build", "node-out"]),
        ("python-envs", "Python environments", rgb(48, 176, 199), ["venv", "venv-plain"]),
        ("native-builds", "Native & JVM builds", rgb(100, 210, 255),
         ["rust-target", "maven-target", "swiftpm", "pods", "gradle-build", "dart-tool", "flutter-build", "elixir-build", "elixir-deps", "composer-vendor", "dotnet-bin", "dotnet-obj", "terraform"]),
        ("project-caches", "Tool caches in projects (.turbo…)", rgb(90, 200, 250), []),
    ]

    private static let cacheColors: [CacheGroup: Color] = [
        .packageManagers: rgb(191, 90, 242),
        .apple: rgb(255, 55, 95),
        .languages: rgb(175, 82, 222),
        .editors: rgb(218, 143, 255),
        .testing: rgb(255, 105, 180),
    ]

    static func breakdown(for result: ScanResult) -> [BreakdownItem] {
        var items: [BreakdownItem] = []

        let artifacts = result.projects.flatMap { $0.artifacts.filter { $0.kind == .folder } }
        var assigned = Set<String>()
        for kind in projectKinds {
            let matching = kind.rules.isEmpty
                ? artifacts.filter { !assigned.contains($0.ruleID) }
                : artifacts.filter { kind.rules.contains($0.ruleID) }
            assigned.formUnion(kind.rules)
            let bytes = matching.reduce(0) { $0 + $1.size.reclaimable }
            items.append(BreakdownItem(id: kind.id, title: kind.title, bytes: bytes, color: kind.color, section: .projects))
        }

        for group in CacheGroup.allCases where group.isDeveloper {
            let bytes = result.caches.filter { $0.group == group }.reduce(0) { $0 + $1.size.reclaimable }
            items.append(BreakdownItem(id: "cache-\(group.rawValue)", title: group.title + (group == .apple ? " caches" : ""),
                                       bytes: bytes, color: cacheColors[group] ?? .purple, section: .caches))
        }

        let backups = result.caches.filter { $0.id.hasPrefix("ios-backup:") }.reduce(0) { $0 + $1.size.reclaimable }
        let browsers = result.caches.filter { $0.group == .browsers }.reduce(0) { $0 + $1.size.reclaimable }
        let otherSystem = result.systemBytes - backups - browsers
        items.append(BreakdownItem(id: "backups", title: "iPhone & iPad backups", bytes: backups, color: rgb(142, 142, 147), section: .systemData))
        items.append(BreakdownItem(id: "browsers", title: "Browser caches", bytes: browsers, color: rgb(255, 120, 70), section: .systemData))
        items.append(BreakdownItem(id: "system-other", title: "App caches, logs & installers", bytes: otherSystem, color: rgb(99, 99, 102), section: .systemData))

        let devices = result.simulators.reduce(0) { $0 + $1.size.reclaimable }
        let runtimes = result.runtimes.filter(\.isDeletable).reduce(0) { $0 + $1.sizeBytes }
        items.append(BreakdownItem(id: "sim-devices", title: "Simulator devices", bytes: devices, color: rgb(255, 159, 10), section: .simulators))
        items.append(BreakdownItem(id: "sim-runtimes", title: "Simulator runtimes", bytes: runtimes, color: rgb(255, 204, 0), section: .simulators))
        items.append(BreakdownItem(id: "docker", title: "Docker", bytes: result.dockerBytes, color: rgb(50, 173, 230), section: .caches))
        items.append(BreakdownItem(id: "trash", title: "Trash", bytes: result.trashBytes, color: rgb(172, 142, 104), section: .trash))

        if let disk = result.disk {
            let other = max(0, disk.used - result.totalReclaimable)
            items.append(BreakdownItem(id: "other", title: "Apps, documents & system", bytes: other, color: Color.gray.opacity(0.55), section: nil))
        }
        return items.filter { $0.bytes > 0 }
    }
}

func formatBytes(_ bytes: Int64) -> String { ByteFormat.string(bytes) }

func relativeDate(_ date: Date?) -> String {
    guard let date else { return "Unknown" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

struct SizeText: View {
    let bytes: Int64
    var isEstimate = false

    var body: some View {
        Text((isEstimate ? "up to " : "") + formatBytes(bytes))
            .monospacedDigit()
            .foregroundStyle(bytes > 0 ? .primary : .secondary)
    }
}

struct TierBadge: View {
    let tier: SafetyTier

    var body: some View {
        Label(tier.title, systemImage: tier.symbol)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tier.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tier.color.opacity(0.12), in: Capsule())
            .help(tier.summary)
    }
}

struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }
}

struct EcosystemBadge: View {
    let ecosystem: Ecosystem?
    var size: CGFloat = 26

    var body: some View {
        let color = ecosystem?.color ?? .gray
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                if let ecosystem {
                    Text(ecosystem.monogram)
                        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.white)
                }
            }
            .help(ecosystem?.title ?? "Project")
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
    }
}

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.separator.opacity(0.5))
                }
        }
    }
}

extension View {
    func card(cornerRadius: CGFloat = 16) -> some View { modifier(CardBackground(cornerRadius: cornerRadius)) }
}

/// A stacked bar showing how the disk is used.
struct StorageBar: View {
    struct Segment: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]
    let total: Int64
    var height: CGFloat = 22
    var showsLegend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        let width = proxy.size.width * CGFloat(Double(segment.bytes) / Double(max(total, 1)))
                        if width >= 1 {
                            Rectangle()
                                .fill(segment.color.gradient)
                                .frame(width: max(2, width - 2))
                                .help("\(segment.title): \(formatBytes(segment.bytes))")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: height * 0.3, style: .continuous))
            }
            .frame(height: height)

            if showsLegend {
                HStack(spacing: 16) {
                    ForEach(segments) { segment in
                        HStack(spacing: 6) {
                            Circle().fill(segment.color).frame(width: 8, height: 8)
                            Text(segment.title).foregroundStyle(.secondary)
                            Text(formatBytes(segment.bytes)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    static func segments(for result: ScanResult) -> [Segment] {
        BreakdownItem.breakdown(for: result).map { Segment(id: $0.id, title: $0.title, bytes: $0.bytes, color: $0.color) }
    }
}

/// Native AppKit checkbox with a mixed state.
struct TriStateCheckbox: NSViewRepresentable {
    let state: CheckState
    var isEnabled = true
    let action: (Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggled(_:)))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.state = state
        button.isEnabled = isEnabled
        switch state {
        case .off: button.state = .off
        case .mixed: button.state = .mixed
        case .on: button.state = .on
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: (Bool) -> Void
        var state: CheckState = .off

        init(action: @escaping (Bool) -> Void) {
            self.action = action
        }

        @objc func toggled(_ sender: NSButton) {
            action(state != .on)
        }
    }
}

struct ReasonLabel: View {
    let text: String
    var isBlocking = true

    var body: some View {
        Label(text, systemImage: isBlocking ? "nosign" : "info.circle")
            .font(.caption)
            .foregroundStyle(isBlocking ? Color.secondary : Color.orange)
            .lineLimit(2)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
    }
}
