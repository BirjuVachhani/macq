//
//  SettingsView.swift
//  MacQ
//
//  Settings window. Opening this shows the Dock icon (handled by AppDelegate);
//  closing it returns MacQ to menu-bar-only.
//

import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var controller: DisplayController
    @State private var tab: Tab = .general

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case sources = "Sources"
        case keyboard = "Keyboard"

        var id: Self { self }
    }

    // A segmented picker in a plain stack rather than a TabView. TabView draws
    // its own full-width tinted strip behind the tabs and pins them to the top
    // edge of the content area, and neither is adjustable from SwiftUI. Driving
    // the same segmented control by hand costs one @State and gives back the
    // window background and the spacing above it.
    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize() // hug the labels instead of stretching across the window
            .padding(.top, 14)
            .padding(.bottom, 10)

            switch tab {
            case .general: GeneralTab()
            case .sources: SourcesTab()
            case .keyboard: KeyboardTab()
            }
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
                Text("Brightness follows the mouse pointer: F1 and F2 change whichever screen the pointer is on. Volume goes to the monitor while it is the sound output device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Status", value: router.status.summary)
                if router.status == .needsAccessibility {
                    Button("Open Accessibility Settings…") {
                        MediaKeyRouter.shared.requestAccessibility()
                    }
                    Text("MacQ needs Accessibility permission to intercept the keys before macOS handles them. Keyboards send brightness as an ordinary key press, so MacQ checks which key each press was and ignores anything that is not brightness, volume or mute. Nothing you type is read, stored or sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Keys to intercept") {
                Toggle("Brightness keys (F1, F2), on the screen under the pointer", isOn: $prefs.brightnessKeysEnabled)
                    .disabled(!prefs.mediaKeysEnabled)
                Toggle("Volume keys (F10, F11, F12)", isOn: $prefs.volumeKeysEnabled)
                    .disabled(!prefs.mediaKeysEnabled)
                Toggle("Show an on-screen level indicator", isOn: $prefs.showOSD)
                    .disabled(!prefs.mediaKeysEnabled)
                Text("Intercepting a key also hides the system indicator, so MacQ draws its own under its menu bar icon, named for the monitor it changed.")
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
                Text("This rule covers the keys only. The volume slider in the menu bar popover always drives the monitor, whatever the Mac is playing through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("MacQ controls one external monitor at a time. If a different external display is active, its keys are left to macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            KeyDiagnosticsSection()
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

/// Live view of the media-key pipeline: which display MacQ thinks is active, and
/// what each keypress did.
///
/// This is the only way to tell apart the three ways a media key can appear to do
/// nothing (the event never arrives, it arrives and is passed to macOS on
/// purpose, or it is claimed and the panel ignores the DDC write). Recording runs
/// only while this section is on screen.
private struct KeyDiagnosticsSection: View {
    @EnvironmentObject var controller: DisplayController
    @ObservedObject private var diagnostics = MediaKeyDiagnostics.shared
    @State private var activeSummary = ""

    /// Focus and pointer both move without notifying us, so the summary is
    /// re-read on a tick rather than observed.
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Diagnostics") {
            LabeledContent("Bound monitor",
                           value: controller.display.map { "\($0.name), id \($0.id)" } ?? "None")
            LabeledContent("Active display", value: activeSummary)

            if diagnostics.entries.isEmpty {
                Text("Press a brightness or volume key. Every media key MacQ sees is listed here with where it went. Nothing at all means the key never reached MacQ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(diagnostics.entries.reversed()) { entry in
                            Text("\(entry.timestamp)  \(entry.text)")
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }

            HStack {
                Button("Clear") { diagnostics.clear() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnostics.transcript, forType: .string)
                }
                .disabled(diagnostics.entries.isEmpty)
            }

            if diagnostics.isFileLogging {
                Text("Also writing to ~/Library/Logs/MacQ/mediakeys.log. Turn it off with `defaults write \(Bundle.main.bundleIdentifier ?? "dev.birjuvachhani.macq") debugKeyLog -bool NO`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Reading this window puts the pointer on it, and the pointer is what the brightness keys follow. To watch the routing with the pointer somewhere else, run `defaults write \(Bundle.main.bundleIdentifier ?? "dev.birjuvachhani.macq") debugKeyLog -bool YES`, relaunch MacQ, and read ~/Library/Logs/MacQ/mediakeys.log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            diagnostics.setPanelVisible(true)
            refreshActive()
        }
        .onDisappear { diagnostics.setPanelVisible(false) }
        .onReceive(tick) { _ in refreshActive() }
    }

    private func refreshActive() {
        let current = ActiveDisplay.shared.currentDisplayID().map(String.init) ?? "unresolved"
        activeSummary = "\(current)  (\(ActiveDisplay.shared.diagnostics()))"
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
