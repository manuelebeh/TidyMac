import SwiftUI
import TidyCore
import UserNotifications

/// TidyMac › Settings (⌘,). Mirrors CleanMyMac's Settings › Notifications and the Menu's "Open at Login".
struct SettingsView: View {
    private static let k = HealthAlerts.Settings.defaultsKey
    private static let d = HealthAlerts.Settings()
    @AppStorage("\(k).lowDisk") private var lowDisk = d.lowDisk
    @AppStorage("\(k).freeSpaceLimit") private var freeSpaceLimit = Int(d.freeSpaceLimit)
    @AppStorage("\(k).trashSize") private var trashSize = d.trashSize
    @AppStorage("\(k).trashLimit") private var trashLimit = Int(d.trashLimit)
    @AppStorage("\(k).memory") private var memory = d.memory
    @AppStorage("\(k).battery") private var battery = d.battery
    @AppStorage("\(k).threats") private var threats = d.threats
    @AppStorage("\(k).externalDrives") private var externalDrives = d.externalDrives
    @AppStorage("\(k).driveConnected") private var driveConnected = d.driveConnected
    @AppStorage("\(k).bluetooth") private var bluetooth = d.bluetooth

    @State private var openAtLogin = HealthMonitor.opensAtLogin
    @State private var loginError: String?
    @State private var authorization: UNAuthorizationStatus?

    private let freeSpaceOptions = [5, 10, 20, 50].map { $0 * 1_000_000_000 }
    private let trashOptions = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000]

    var body: some View {
        Form {
            if authorization == .denied {
                Section {
                    HStack {
                        Label("Notifications are turned off for TidyMac.", systemImage: "bell.slash")
                        Spacer()
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            }
            Section("Disk Space") {
                limitRow("Warn when free space is less than", isOn: $lowDisk, limit: $freeSpaceLimit, options: freeSpaceOptions)
                limitRow("Notify if Trash size exceeds", isOn: $trashSize, limit: $trashLimit, options: trashOptions)
                if trashSize, SystemMonitor.trash() == nil {
                    Text("Allow Full Disk Access to analyze Trash contents.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Suggest to clean up overfilled external drives", isOn: $externalDrives)
                Toggle("Notify when a drive is connected to the Mac", isOn: $driveConnected)
            }
            Section("General") {
                Toggle("Notify when too low on free RAM", isOn: $memory)
                Toggle("Warn about critical battery health", isOn: $battery)
                Toggle("Warn when connected device batteries are running low", isOn: $bluetooth)
            }
            Section {
                Toggle("Notify about detected threats", isOn: $threats)
            } header: {
                Text("Protection")
            } footer: {
                Text("Checks launch agents and daemons every 15 minutes while TidyMac or its menu is running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { on in
                    do { try HealthMonitor.setOpensAtLogin(on); loginError = nil } catch { loginError = error.localizedDescription }
                    openAtLogin = HealthMonitor.opensAtLogin
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Menu")
            } footer: {
                Text("Keeps the menu and its alerts running after a restart.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            guard Bundle.main.bundleIdentifier != nil else { return }
            authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    private func limitRow(_ title: String, isOn: Binding<Bool>, limit: Binding<Int>, options: [Int]) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            Picker(title, selection: limit) {
                ForEach(options, id: \.self) { Text(FileSize.format(Int64($0))).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!isOn.wrappedValue)
        }
    }
}
