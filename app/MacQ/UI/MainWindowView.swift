//
//  MainWindowView.swift
//  MacQ
//
//  Onboarding window shown at launch: what MacQ does and where to find it.
//  "Get Started" hides the window but keeps MacQ running in the menu bar.
//

import SwiftUI
import AppKit

struct MainWindowView: View {
    @EnvironmentObject var controller: DisplayController
    @ObservedObject private var updater = UpdaterController.shared

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            features
            Spacer(minLength: 8)
            if updater.isUpdateAvailable {
                updateBanner
            }
            monitorStatus
            footer
        }
        .frame(width: 420, height: 600)
        .background(.windowBackground)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            Text("Welcome to MacQ")
                .font(.system(size: 24, weight: .bold))
            Text("Control your BenQ monitor from the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .padding(.horizontal, 24)
    }

    // MARK: Features

    private var features: some View {
        VStack(alignment: .leading, spacing: 18) {
            FeatureRow(icon: "arrow.left.arrow.right", tint: .blue,
                       title: "Switch inputs",
                       detail: "Jump between USB-C, HDMI 1, and HDMI 2 in a click.")
            FeatureRow(icon: "sun.max.fill", tint: .orange,
                       title: "Adjust brightness",
                       detail: "Set the panel's backlight without the on-screen menu.")
            FeatureRow(icon: "speaker.wave.2.fill", tint: .purple,
                       title: "Adjust volume",
                       detail: "Control the monitor's built-in speaker volume.")
        }
        .padding(.horizontal, 28)
    }

    // MARK: Update

    /// Sits above the monitor status, and only once a check has found a newer
    /// version. MacQ checks at launch and then hourly, so this window is often
    /// where someone first learns an update exists.
    private var updateBanner: some View {
        Button {
            updater.checkForUpdates()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update to latest version")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let available = updater.availableVersion {
                        Text("Version \(available) is available. You have \(version).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!updater.canActOnUpdates)
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    // MARK: Status

    private var monitorStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.availability.isAvailable ? "checkmark.circle.fill" : "display")
                .foregroundStyle(controller.availability.isAvailable ? Color.green : .secondary)
            Text(controller.display?.name ?? "No external monitor connected")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 24)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            Text("MacQ lives in the menu bar. Click the monitor icon at the top of your screen to open the controls.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.large)
                Button("Get Started") { (NSApp.delegate as? AppDelegate)?.hideMainWindow() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }

            Text("MacQ \(version)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 20)
    }
}

private struct FeatureRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
