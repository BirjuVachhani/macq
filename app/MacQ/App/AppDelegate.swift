//
//  AppDelegate.swift
//  MacQ
//
//  Owns the menu-bar status item + popover, the main window, and the Settings
//  window. MacQ shows a Dock icon while any window is open and drops to
//  menu-bar-only (accessory) when they all close.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        showMainWindow() // greet the user with a window on launch
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // menu-bar app: closing a window must not quit it
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true // force-show even if a prior state hid it
        guard let button = statusItem.button else {
            NSLog("MacQ: status item has no button")
            return
        }
        if let icon = NSImage(named: "TrayIcon") {
            // Template rendering makes the menu bar tint the glyph itself: black on
            // a light menu bar, white on a dark one, and inverted while highlighted.
            // The asset already ships as a monochrome template; forcing the flag
            // here guarantees it regardless of how the image is drawn.
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.image?.isTemplate = true
            button.contentTintColor = nil // let the system tint drive the color
        } else {
            button.title = "MacQ" // fallback so the item is never invisible
        }
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    private func setUpPopover() {
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: MenuContent().environmentObject(DisplayController.shared)
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            DisplayController.shared.refresh() // sync current state on open
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    // MARK: - NSPopoverDelegate (poll live values while the popover is open)

    func popoverDidShow(_ notification: Notification) {
        pollTimer?.invalidate()
        // Refresh-on-open already ran in togglePopover; keep values live after.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            DisplayController.shared.syncValues()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Windows

    /// Shown at launch and reachable again if needed. Hiding it keeps MacQ
    /// running in the menu bar.
    func showMainWindow() {
        closePopover()
        if mainWindow == nil {
            mainWindow = makeWindow(title: "MacQ", content: MainWindowView(), resizable: false)
        }
        present(mainWindow!)
    }

    func hideMainWindow() {
        mainWindow?.close() // windowWillClose drops the Dock icon
    }

    /// Opens (or focuses) the Settings window.
    func showSettings() {
        closePopover()
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "MacQ Settings", content: SettingsView(), resizable: true)
        }
        present(settingsWindow!)
    }

    private func makeWindow<Content: View>(title: String, content: Content, resizable: Bool) -> NSWindow {
        let hosting = NSHostingController(rootView: content.environmentObject(DisplayController.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { mask.insert(.resizable) }
        window.styleMask = mask
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular) // show Dock icon while a window is open
        NSApp.activate(ignoringOtherApps: true)
        window.center() // open in the middle of the screen (size is settled by now)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Re-evaluate after the window has actually closed.
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }

    private func updateActivationPolicy() {
        let anyWindowVisible = [mainWindow, settingsWindow].contains { $0?.isVisible == true }
        NSApp.setActivationPolicy(anyWindowVisible ? .regular : .accessory)
    }
}
