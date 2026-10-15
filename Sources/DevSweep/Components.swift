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
        }
    }
}

extension Project {
    var lastActiveSort: Date { lastActive ?? .distantPast }
    var primaryEcosystem: Ecosystem? { ecosystems.first }
}

enum Category: String, CaseIterable, Identifiable {
    case projects, caches, simulators, docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Project build files"
        case .caches: "Caches"
        case .simulators: "Simulators"
        case .docker: "Docker"
        }
    }

    var color: Color {
        switch self {
        case .projects: .blue
        case .caches: .purple
        case .simulators: .orange
        case .docker: .cyan
        }
    }

    var symbol: String {
        switch self {
        case .projects: "folder.fill"
        case .caches: "archivebox.fill"
        case .simulators: "iphone.gen3"
        case .docker: "shippingbox.fill"
        }
    }

    func bytes(in result: ScanResult) -> Int64 {
        switch self {
        case .projects: result.projectBytes
        case .caches: result.cacheBytes
        case .simulators: result.simulatorBytes
        case .docker: result.dockerBytes
        }
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
        var segments = Category.allCases.map { category in
            Segment(id: category.rawValue, title: category.title, bytes: category.bytes(in: result), color: category.color)
        }
        if let disk = result.disk {
            let other = max(0, disk.used - result.totalReclaimable)
            segments.append(Segment(id: "other", title: "Everything else", bytes: other, color: Color.gray.opacity(0.55)))
        }
        return segments
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
