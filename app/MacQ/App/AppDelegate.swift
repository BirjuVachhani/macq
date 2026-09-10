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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var updateMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()
        setUpStatusItem()
        setUpPopover()
        setUpMediaKeys()
        // Starts Sparkle's hourly check timer and runs the launch check, so
        // both happen once, here, rather than whenever a view first touches the
        // shared controller.
        UpdaterController.shared.start()
        showMainWindow() // greet the user with a window on launch
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // menu-bar app: closing a window must not quit it
    }

    // MARK: - Main menu

    /// MacQ ships without a MainMenu nib, so there is no menu bar at all unless
    /// one is built here. It is only on screen while MacQ is a regular app,
    /// which is to say while one of its windows is open, but that is exactly
    /// when someone reaches for the menu bar.
    ///
    /// Nothing here is decorative: the Edit menu is what gives the text fields
    /// in Settings their Cut/Copy/Paste and Undo key equivalents, which AppKit
    /// wires through menu items rather than the fields themselves.
    private func setUpMainMenu() {
        let appName = ProcessInfo.processInfo.processName
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                           action: #selector(openSettingsFromMenu),
                                           keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        attach(appMenu, to: mainMenu)

        let fileMenu = NSMenu(title: "File")
        // Held here rather than in the app menu because that is where this was
        // asked for. Its title is fixed: whether an update is waiting is said
        // by the row in the popover and the main window, and a menu item that
        // renames itself is harder to find than one that does not.
        updateMenuItem = fileMenu.addItem(withTitle: "Check for Updates…",
                                          action: #selector(checkForUpdatesFromMenu),
                                          keyEquivalent: "")
        updateMenuItem?.target = self
        fileMenu.addItem(.separator())
        let mainWindowItem = fileMenu.addItem(withTitle: "Welcome Window",
                                              action: #selector(showMainWindowFromMenu),
                                              keyEquivalent: "0")
        mainWindowItem.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        attach(fileMenu, to: mainMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        attach(editMenu, to: mainMenu)

        NSApp.mainMenu = mainMenu
    }

    /// A top-level menu is a menu item whose only job is to hold a submenu.
    private func attach(_ submenu: NSMenu, to mainMenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        mainMenu.addItem(item)
    }

    @objc private func checkForUpdatesFromMenu() {
        UpdaterController.shared.checkForUpdates()
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    @objc private func showMainWindowFromMenu() {
        showMainWindow()
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdatesFromMenu) {
            // False for the duration of a check that is already running, which
            // is exactly when a second one would be dropped on the floor.
            return UpdaterController.shared.canActOnUpdates
        }
        return true
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

    /// Also called by UpdaterController once Sparkle's UI is dismissed: it
    /// promotes MacQ to a regular app to show an update window, and only this
    /// knows whether a window of MacQ's own is still open underneath.
    func updateActivationPolicy() {
        let anyWindowVisible = [mainWindow, settingsWindow].contains { $0?.isVisible == true }
        NSApp.setActivationPolicy(anyWindowVisible ? .regular : .accessory)
    }
}
