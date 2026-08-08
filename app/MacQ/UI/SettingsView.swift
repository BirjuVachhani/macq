//
//  SettingsView.swift
//  MacQ
//
//  Settings window. Opening this shows the Dock icon (handled by AppDelegate);
//  closing it returns MacQ to menu-bar-only.
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var controller: DisplayController

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            SourcesTab().tabItem { Label("Sources", systemImage: "rectangle.on.rectangle") }
            KeyboardTab().tabItem { Label("Keyboard", systemImage: "keyboard") }
        }
        // min sizes let the window be resized; ideal sets the size it opens at,
        // tall enough that every setting is visible without scrolling.
        .frame(minWidth: 480, idealWidth: 480, minHeight: 560, idealHeight: 560)
        .background(.windowBackground)
        .environmentObject(controller)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var controller: DisplayController
    @State private var launchAtLogin = LoginItem.isEnabled

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "MacQ \(v)"
    }

    var body: some View {
        Form {
            Section("Application") {
                LabeledContent("Version", value: version)
                LabeledContent("Menu bar", value: "Always visible")
            }
            Section("Startup") {
                Toggle("Launch MacQ at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        try? LoginItem.setEnabled(newValue)
                        launchAtLogin = LoginItem.isEnabled // re-sync with the system
                    }
                if LoginItem.needsApproval {
                    Text("Approve MacQ in System Settings › General › Login Items to finish enabling this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Detected monitor") {
                if let display = controller.display {
                    LabeledContent("Name", value: display.name)
                    LabeledContent("Identifier", value: display.persistentKey)
                    LabeledContent("Status", value: controller.availability.isAvailable
                                   ? "Controllable (DDC/CI)"
                                   : (controller.availability.reason ?? "Unavailable"))
                } else {
                    Text("No external monitor connected.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    controller.refresh()
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                Text(controller.lastSyncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SourcesTab: View {
    @EnvironmentObject var controller: DisplayController

    var body: some View {
        Form {
            if controller.display != nil, !controller.sources.isEmpty {
                Section("Rename input sources") {
                    ForEach(controller.sources) { source in
                        AliasRow(source: source)
                    }
                }
                Section {
                    Text("Names are saved per monitor. Leave blank to use the default name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Connect a monitor to configure its input sources.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyboardTab: View {
    @EnvironmentObject var controller: DisplayController
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var router = MediaKeyRouter.shared
    @State private var outputDevice: String?

    /// The sound output device can change without MacQ doing anything, and
    /// CoreAudio's listener lives well below the UI layer, so the label is
    /// simply re-read on a slow tick while this tab is on screen.
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Media keys") {
                Toggle("Use keyboard brightness and volume keys on the monitor", isOn: $prefs.mediaKeysEnabled)
                Text("When the monitor is the active display, the keys change the monitor over DDC/CI instead of the Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: router.status.summary)
                if router.status == .needsAccessibility {
                    Button("Open Accessibility Settings…") {
                        MediaKeyRouter.shared.requestAccessibility()
                    }
                    Text("MacQ needs Accessibility permission to intercept the keys before macOS handles them. Nothing else is read from your keyboard: only the brightness, volume and mute keys are inspected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Keys to intercept") {
                Toggle("Brightness keys (F1, F2)", isOn: $prefs.brightnessKeysEnabled)
                    .disabled(!prefs.mediaKeysEnabled)
                Toggle("Volume keys (F10, F11, F12)", isOn: $prefs.volumeKeysEnabled)
                    .disabled(!prefs.mediaKeysEnabled)
                Toggle("Show an on-screen level indicator", isOn: $prefs.showOSD)
                    .disabled(!prefs.mediaKeysEnabled)
                Text("Intercepting a key also hides the system indicator, so MacQ draws its own on the monitor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Volume keys apply to the monitor") {
                Picker("", selection: $prefs.volumeKeyRule) {
                    ForEach(VolumeKeyRule.allCases) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(!prefs.mediaKeysEnabled || !prefs.volumeKeysEnabled)
                Text(prefs.volumeKeyRule.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Sound output", value: outputDevice ?? "Unknown")
                LabeledContent("Monitor owns the sound",
                               value: controller.monitorIsAudioOutput ? "Yes" : "No")
                Text("MacQ never changes the monitor's volume or mute while the Mac is playing somewhere else, whichever option is selected above. On some panels that would wake the monitor's own speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("MacQ controls one external monitor at a time. If a different external display is active, its keys are left to macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            outputDevice = MonitorAudioBinding.shared.currentOutputDeviceName()
            controller.refreshAudioOutputState()
        }
        .onReceive(tick) { _ in
            outputDevice = MonitorAudioBinding.shared.currentOutputDeviceName()
            controller.refreshAudioOutputState()
        }
    }
}

private struct AliasRow: View {
    let source: InputSource
    @EnvironmentObject var controller: DisplayController
    @State private var text = ""

    var body: some View {
        HStack {
            Text(source.defaultLabel)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField(source.defaultLabel, text: $text)
                .textFieldStyle(.roundedBorder)
        }
        .onAppear { text = controller.alias(for: source) ?? "" }
        .onChange(of: text) { _, newValue in
            controller.setAlias(newValue, for: source)
        }
    }
}

/// Launch-at-login via the modern ServiceManagement API (macOS 13+). The system
/// is the source of truth, so there is nothing to persist ourselves; off by
/// default because we never register unless the user turns it on.
enum LoginItem {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// True once registered but still awaiting the user's approval in System Settings.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if enabled {
            guard status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status == .enabled || status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
