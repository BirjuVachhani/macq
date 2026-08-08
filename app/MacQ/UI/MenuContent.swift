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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            if controller.availability.isAvailable {
                sourcesSection
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
                .disabled(!controller.monitorIsAudioOutput)
                if !controller.monitorIsAudioOutput {
                    Text("Sound is not playing through this monitor, so its volume is left alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(controller.availability.reason ?? "Unavailable")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 2) {
            MenuActionRow(title: "Sync now", systemImage: "arrow.clockwise") {
                controller.refresh()
            }
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
