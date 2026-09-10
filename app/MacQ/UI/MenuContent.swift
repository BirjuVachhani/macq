//
//  MenuContent.swift
//  MacQ
//
//  The menu-bar overlay (MenuBarExtra window content). Phase 1 focuses on the
//  input-source list; brightness/volume sliders arrive in phases 2 and 3.
//

import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var controller: DisplayController
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var updater = UpdaterController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if updater.isUpdateAvailable {
                updateBanner
            }
            Divider()

            if controller.availability.isAvailable {
                sourcesSection
                if controller.supportsAutoInputDetect {
                    autoDetectToggle
                }
                if controller.supportsBrightness || controller.supportsVolume {
                    Divider()
                    controlsSection
                }
            } else {
                unavailableView
            }

            Divider()
            actions
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 22))
                .foregroundStyle(controller.availability.isAvailable ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.display?.name ?? "MacQ")
                    .font(.headline)
                    .lineLimit(1)
                Text(controller.lastSyncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if controller.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Update

    /// Shown only once a check has found a newer version. Deliberately a banner
    /// rather than another row in the actions list: it is the one thing here
    /// that is news, and the actions below already hold a "Check for updates…"
    /// row that calls the same method, which would read as a duplicate.
    private var updateBanner: some View {
        Button {
            updater.checkForUpdates()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update to latest version")
                        .font(.subheadline.weight(.semibold))
                    if let version = updater.availableVersion {
                        Text("Version \(version) is available")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!updater.canActOnUpdates)
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(controller.sources) { source in
                SourceRow(
                    label: controller.label(for: source),
                    isActive: controller.isActive(source),
                    action: { controller.selectInput(source) }
                )
                .disabled(controller.isBusy)
            }
        }
    }

    // MARK: Auto input detect

    private var autoDetectToggle: some View {
        // Laid out by hand rather than as Toggle's own label: the switch style
        // reserves trailing slack next to a multi-line label, which leaves the
        // switch floating short of the popover's content edge. A Spacer pins it
        // flush with the dividers and the source rows' trailing text.
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto input detect")
                    .font(.subheadline.weight(.medium))
                Text("Let the monitor pick a live source")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("Auto input detect", isOn: Binding(
                get: { prefs.preserveAutoInputDetect },
                set: { controller.setAutoInputDetect($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .disabled(controller.isBusy)
    }

    // MARK: Brightness / volume

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controller.supportsBrightness {
                ControlSlider(
                    title: "Brightness",
                    systemImage: "sun.max",
                    value: brightnessBinding,
                    range: 0...Double(controller.brightnessMax),
                    onEditingChanged: { editing in
                        editing ? controller.beginEditingBrightness() : controller.endEditingBrightness()
                    }
                )
            }
            if controller.supportsVolume {
                ControlSlider(
                    title: "Volume",
                    systemImage: "speaker.wave.2",
                    value: volumeBinding,
                    range: 0...Double(controller.volumeMax),
                    onEditingChanged: { editing in
                        editing ? controller.beginEditingVolume() : controller.endEditingVolume()
                    }
                )
            }
        }
    }

    private var brightnessBinding: Binding<Double> {
        Binding(get: { Double(controller.brightness) },
                set: { controller.setBrightness(Int($0.rounded())) })
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { Double(controller.volume) },
                set: { controller.setVolume(Int($0.rounded())) })
    }

    private var unavailableView: some View {
        // A monitor MacQ itself turned off is unavailable on purpose; the
        // generic reason ("enable DDC/CI in the OSD") would be wrong and
        // alarming there, so that state gets its own calm message.
        //
        // The wording says "connection" on purpose. What MacQ switched off is
        // this Mac's link to the panel, and the panel can be lit again without
        // MacQ knowing: press its power button, or let it find another machine
        // on a second input. Claiming "the monitor is off" next to a screen
        // that is visibly on reads as a bug, and Sync now cannot fix it,
        // because with the link disabled there is nothing left to sync.
        let offByMacQ = controller.powerState == .offByMacQ
        return HStack(spacing: 8) {
            Image(systemName: offByMacQ ? "moon.zzz" : "exclamationmark.triangle")
                .foregroundStyle(offByMacQ ? Color.secondary : Color.orange)
            Text(offByMacQ
                 ? "MacQ turned off this Mac's connection to the monitor. Use Wake monitor to reconnect."
                 : (controller.availability.reason ?? "Unavailable"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 2) {
            if controller.showsPowerActions {
                MenuActionRow(title: "Turn monitor off", systemImage: "moon.fill") {
                    controller.turnMonitorOff()
                }
                // Not gated on availability: turning the monitor off drops its
                // video signal rather than talking DDC, so it still works on a
                // panel that has stopped answering VCP reads.
                .disabled(!controller.supportsPowerControl
                          || controller.powerState != .normal)
                // Deliberately gated only on a wake already in flight: a
                // sleeping panel reads as unavailable and cannot answer a
                // capability probe, and the recovery ladder flips isBusy while
                // retrying, so any of those gates would lock the user out of
                // the one action that helps.
                MenuActionRow(title: controller.powerState == .waking ? "Waking monitor…" : "Wake monitor",
                              systemImage: "power.circle") {
                    controller.wakeMonitor()
                }
                .disabled(controller.powerState == .waking)
            }
            MenuActionRow(title: "Sync now", systemImage: "arrow.clockwise") {
                controller.refresh()
            }
            MenuActionRow(title: "Check for updates…", systemImage: "arrow.down.circle") {
                updater.checkForUpdates()
            }
            // False for the duration of a check that is already running, which
            // is exactly when a second one would be dropped on the floor.
            .disabled(!updater.canCheckForUpdates)
            MenuActionRow(title: "Settings…", systemImage: "gearshape") {
                (NSApp.delegate as? AppDelegate)?.showSettings()
            }
            MenuActionRow(title: "Quit MacQ", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Rows

private struct SourceRow: View {
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                if isActive {
                    Text("Active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ControlSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(value.rounded()))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
    }
}

private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
