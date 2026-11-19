import AppKit
import OSLog
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private static let log = Logger(subsystem: "dev.nsuz.Inbox", category: "settings")

    @Binding var showsMenuBarExtra: Bool
    @State private var loginItem = SMAppService.mainApp.status
    @State private var loginItemChangeFailed = false

    var body: some View {
        Form {
            Section {
                ForEach(ReasonGroup.allCases) { group in
                    ReasonToggle(group: group)
                }
            } header: {
                Text("Notify me about")
            } footer: {
                Text("Inbox always lists every unread notification. These settings only decide which ones show a banner.")
            }
            Section {
                SoundPicker()
            } footer: {
                Text("To turn the sound off, go to Notifications in System Settings.")
            }
            Section {
                Toggle("Show in menu bar", isOn: $showsMenuBarExtra)
                Toggle("Open at login", isOn: Binding(get: { loginItem == .enabled }, set: setOpensAtLogin))
                if loginItem == .requiresApproval {
                    Button("Approve in System Settings…", action: SMAppService.openSystemSettingsLoginItems)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        // A grouped form scrolls, so without this the window keeps whatever height it was given
        // and cuts off the sections below.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshLoginItem)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItem()
        }
        .alert("Couldn’t Change Open at Login", isPresented: $loginItemChangeFailed) {
            Button("Open Login Items Settings", action: SMAppService.openSystemSettingsLoginItems)
            Button("OK", role: .cancel) {}
        } message: {
            Text("macOS didn’t accept the change. You can check Inbox in Login Items & Extensions in System Settings.")
        }
    }

    // The system owns this state: the toggle shows what reading the status back says, not what
    // was asked for, so it is right after a failed call or a change made in System Settings.
    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            Self.log.error("Couldn’t \(enabled ? "register" : "unregister", privacy: .public) the login item: \(error, privacy: .public)")
            loginItemChangeFailed = true
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        loginItem = SMAppService.mainApp.status
    }
}

private struct ReasonToggle: View {
    let group: ReasonGroup
    @AppStorage private var isMuted: Bool

    init(group: ReasonGroup) {
        self.group = group
        _isMuted = AppStorage(wrappedValue: false, group.mutedKey)
    }

    var body: some View {
        Toggle(group.title, isOn: Binding(get: { !isMuted }, set: { isMuted = !$0 }))
    }
}

private struct SoundPicker: View {
    @AppStorage(NotificationSound.key) private var sound: String?

    var body: some View {
        Picker("Sound", selection: $sound) {
            Text("Default").tag(String?.none)
            Divider()
            ForEach(NotificationSound.names, id: \.self) { name in
                Text(verbatim: name).tag(Optional(name))
            }
        }
        // The default sound has no name to play it by outside a notification.
        .onChange(of: sound) { _, name in
            if let name {
                NSSound(named: name)?.play()
            }
        }
    }
}
