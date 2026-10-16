import AppKit
import ServiceManagement
import SwiftUI
import SweepCore
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model

        TabView {
            Form {
                Section {
                    PathList(paths: $model.settings.roots, emptyText: "Add a folder to scan")
                } header: {
                    Text("Folders to scan")
                } footer: {
                    Text("Library, Applications, Music, Movies and Pictures in your home folder are always skipped.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    PathList(paths: $model.settings.excludedPaths, emptyText: "No exclusions")
                } header: {
                    Text("Never scan")
                }

                Section("Projects") {
                    Picker("Treat a project as inactive after", selection: $model.settings.inactiveDays) {
                        ForEach([14, 30, 60, 90, 180, 365], id: \.self) { days in
                            Text(days < 365 ? "\(days) days" : "1 year").tag(days)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Scanning", systemImage: "magnifyingglass") }

            Form {
                Section("Cleaning") {
                    Picker("Default action", selection: $model.settings.deleteMode) {
                        ForEach(DeleteMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    Text("You can change this every time in the review sheet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Automation") {
                    Toggle("Scan once a week in the background", isOn: $model.weeklyScan)
                    Text("You get a notification when more than 5 GB can be freed. Nothing is ever deleted automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Show in the menu bar", isOn: $model.showsMenuBarIcon)
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Cleaning", systemImage: "sparkles") }

            Form {
                Section {
                    LabeledContent("Full Disk Access") {
                        if model.hasFullDiskAccess {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Open System Settings") { model.openFullDiskAccessSettings() }
                        }
                    }
                } footer: {
                    Text("Full Disk Access lets DevMop measure caches inside Library. It only reads folder sizes and never opens your documents, mail or messages.")
                        .foregroundStyle(.secondary)
                }

                Section("Data") {
                    LabeledContent("History and last scan") {
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: History.directory, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([History.directory])
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 460)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let status = SMAppService.mainApp.status
        // The toggle is being reset to match reality after an error, not changed by the person.
        if enabled == (status == .enabled) { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = SMAppService.mainApp.status == .requiresApproval
                ? "Allow DevMop in System Settings › General › Login Items."
                : nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct PathList: View {
    @Binding var paths: [String]
    let emptyText: String
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(paths, id: \.self) { path in
                    Label(path.abbreviatingHome, systemImage: "folder")
                        .tag(path)
                }
            }
            .frame(minHeight: 90)
            .overlay {
                if paths.isEmpty {
                    Text(emptyText).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                Button {
                    addFolder()
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 18)
                }
                Button {
                    if let selection { paths.removeAll { $0 == selection } }
                    selection = nil
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 18)
                }
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !paths.contains(url.path) {
            paths.append(url.path)
        }
    }
}

/// Weekly background scans and the notification that follows them.
@MainActor
final class Automation {
    static let shared = Automation()

    private var scheduler: NSBackgroundActivityScheduler?
    private let notifyThreshold: Int64 = 5_000_000_000

    private var isScheduled = false

    /// Starts or stops the weekly scan; calling it again with the setting unchanged keeps the existing schedule.
    func configure(for model: AppModel) {
        if model.weeklyScan == isScheduled { return }
        scheduler?.invalidate()
        scheduler = nil
        isScheduled = model.weeklyScan
        guard model.weeklyScan else { return }

        let scheduler = NSBackgroundActivityScheduler(identifier: "app.devmop.weekly-scan")
        scheduler.repeats = true
        scheduler.interval = 7 * 24 * 60 * 60
        scheduler.tolerance = 6 * 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak model] completion in
            Task { @MainActor in
                guard let model, !model.isScanning, model.cleanPhase == nil else {
                    completion(.deferred)
                    return
                }
                await model.scan()
                if let result = model.result, result.totalReclaimable >= self.notifyThreshold {
                    self.notify(bytes: result.totalReclaimable)
                }
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asks for notification permission once the person has used the app, not at first launch.
    func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(bytes: Int64) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(formatBytes(bytes)) can be freed"
        content.body = "Open DevMop to review build folders and caches you no longer need."
        let request = UNNotificationRequest(identifier: "weekly-scan", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
