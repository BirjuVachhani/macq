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
        setUpMediaKeys()
        showMainWindow() // greet the user with a window on launch
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // menu-bar app: closing a window must not quit it
    }

    // MARK: - Media keys

    private func setUpMediaKeys() {
        MediaKeyRouter.shared.start()

        // An event tap does not survive these transitions. It is silently
        // destroyed rather than disabled, so there is no tapDisabled callback to
        // recover from and the keys would simply stop working until relaunch.
        let wc = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didWakeNotification,
                                          NSWorkspace.sessionDidBecomeActiveNotification,
                                          NSWorkspace.screensDidWakeNotification] {
            wc.addObserver(self, selector: #selector(restartMediaKeys), name: name, object: nil)
        }
    }

    @objc private func restartMediaKeys() {
        MediaKeyRouter.shared.restart()
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

        // The media-key level indicator hangs under this icon, so it has to know
        // where the icon ended up. A closure rather than the status item itself
        // keeps MediaKeyHUD out of the app layer, and it is asked again on every
        // show because the icon shifts whenever another menu-bar app comes or
        // goes and follows the menu bar between displays.
        MediaKeyHUD.shared.menuBarAnchor = { [weak self] in self?.statusItemScreenFrame }
    }

    /// MacQ's menu-bar icon in screen coordinates, or nil when there is no icon
    /// on screen: the user or a menu-bar manager has hidden the item, or the
    /// window server never placed it.
    ///
    /// A crowded menu bar (on a MacBook, usually the notch) can leave an item
    /// placed but never drawn, which `isVisible` still reports as true, so the
    /// frame is sanity-checked rather than trusted. Callers treat nil as "put it
    /// somewhere else", not as an error.
    private var statusItemScreenFrame: CGRect? {
        guard let statusItem, statusItem.isVisible,
              let button = statusItem.button,
              let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard frame.width > 1, frame.height > 1 else { return nil }
        return frame
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
        // Set after the window is on screen: SwiftUI writes this property itself
        // while it lays the hosted content out, and sees a scrollable Form, so a
        // value set at construction time is overwritten before it is ever drawn.
        // Both windows put plain background under the titlebar rather than a list
        // that scrolls beneath it, so the separator has nothing to separate.
        DispatchQueue.main.async {
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
        }
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
