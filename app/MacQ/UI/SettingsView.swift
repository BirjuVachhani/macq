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
