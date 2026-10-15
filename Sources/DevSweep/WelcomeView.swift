import SwiftUI

/// Shown once on first launch: what DevSweep does and how to grant Full Disk Access.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to DevSweep").font(.title.weight(.semibold))
                    Text("See where your disk space goes and free what you don't need.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                point("eye", "Nothing is deleted until you review the list and confirm.")
                point("arrow.uturn.backward", "Most items go to the Trash, so you can put them back.")
                point("lock.shield", "Nothing leaves your Mac. No accounts, no tracking.")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("One step: allow Full Disk Access").font(.headline)
                Text("macOS protects Library, Mail, Photos and the Trash. DevSweep needs access to measure them; it only reads sizes and names.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Click Open System Settings.")
                    Text("2. Turn on DevSweep in the list, or click + and choose it in Applications.")
                    Text("3. Come back here and click Scan My Mac.")
                }
                .font(.callout)
            }
            .padding(14)
            .card(cornerRadius: 12)

            HStack {
                if model.hasFullDiskAccess {
                    Label("Full Disk Access is on", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Skip for Now") { finish() }
                if !model.hasFullDiskAccess {
                    Button("Open System Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Scan My Mac") {
                        finish()
                        Task { await model.scan() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 520)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
        }
    }

    private func finish() {
        model.hasSeenWelcome = true
        dismiss()
    }
}
