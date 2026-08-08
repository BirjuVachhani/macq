//
//  ActiveDisplay.swift
//  MacQ
//
//  Resolves which display is "active": the one holding the focused window, with
//  the display under the pointer as the fallback.
//
//  THREADING CONTRACT
//    - `currentDisplayID()` and `isActive(_:)` are safe from any thread,
//      including the event-tap callback. They never do IPC, never block on the
//      main thread and never call AppKit. Worst case they take an uncontended
//      os_unfair_lock and compare a handful of rects.
//    - `start()` and `stop()` are main thread only.
//    - The Accessibility walk runs on a private serial queue, never on the main
//      thread and never on the tap thread. AXUIElementCopyAttributeValue is a
//      synchronous mach round trip into another process and can block for the
//      whole messaging timeout when that process is busy.
//

import AppKit
import ApplicationServices
import CoreGraphics
import os

final class ActiveDisplay {

    static let shared = ActiveDisplay()

    // MARK: - Tuning

    /// Recompute in the background when the cached focus answer is older than
    /// this. The notifications normally keep it far fresher; this is the net.
    private let refreshAfter: TimeInterval = 0.25

    /// Past this age the cached focus answer is not trusted at all and the
    /// pointer answers instead. Only reachable when every invalidation source
    /// has failed, for instance a frontmost app that exposes no AX and never
    /// activates again.
    private let distrustAfter: TimeInterval = 5.0

    /// Per-element AX messaging timeout. The process-wide default is multiple
    /// seconds; MacQ would rather give up quickly and fall back to the pointer.
    private let axTimeout: Float = 0.25

    // MARK: - Cached state, guarded by `lock`

    private struct Box {
        let id: CGDirectDisplayID // mirror-master id
        let bounds: CGRect        // CG global space: top-left origin, +y down
    }

    private struct Snapshot {
        var layout: [Box] = []
        var focusID: CGDirectDisplayID = 0   // 0 means unresolved
        var focusStamp: UInt64 = 0           // DispatchTime uptime nanoseconds
        var stickyID: CGDirectDisplayID = 0  // last answer that was not MacQ itself
        var refreshInFlight = false
    }

    private var snapshot = Snapshot()

    // Allocated rather than stored as a struct property: Swift's exclusivity
    // rules can hand `&self.lock` a copy of the struct, which silently gives no
    // mutual exclusion at all.
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    // MARK: - Owned by the AX queue

    private let axQueue = DispatchQueue(label: "dev.birjuvachhani.MacQ.activedisplay",
                                        qos: .userInitiated)
    private let systemWide: AXUIElement = AXUIElementCreateSystemWide()

    // MARK: - Owned by the main thread

    private var observer: AXObserver?
    private var observedAppElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var observedPID: pid_t = 0
    private var started = false

    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private init() {
        lock.initialize(to: os_unfair_lock())
        AXUIElementSetMessagingTimeout(systemWide, axTimeout)
        rebuildLayout()
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Callable from the event-tap thread

    /// The display MacQ should drive right now, or nil if nothing resolves.
    /// Non-blocking: no IPC, no AppKit.
    func currentDisplayID() -> CGDirectDisplayID? {
        let now = DispatchTime.now().uptimeNanoseconds

        os_unfair_lock_lock(lock)
        let layout = snapshot.layout
        let focusID = snapshot.focusID
        let stickyID = snapshot.stickyID
        let age = snapshot.focusStamp == 0
            ? Double.greatestFiniteMagnitude
            : Double(now &- snapshot.focusStamp) / 1_000_000_000.0
        let shouldRefresh = (age > refreshAfter) && !snapshot.refreshInFlight
        if shouldRefresh { snapshot.refreshInFlight = true }
        os_unfair_lock_unlock(lock)

        if shouldRefresh { axQueue.async { [weak self] in self?.recomputeFocus() } }

        // A fresh-enough focus answer wins.
        if focusID != 0, age <= distrustAfter { return focusID }

        // Otherwise the pointer decides. That covers "no focused window
        // resolves" and also a wedged AX path.
        if let byPointer = pointerDisplayID(in: layout) { return byPointer }

        if focusID != 0 { return focusID }
        return stickyID != 0 ? stickyID : nil
    }

    /// True when `id`, a mirror-master display id such as the one MacQ is bound
    /// to, is the active display. Safe from the tap callback.
    func isActive(_ id: CGDirectDisplayID) -> Bool {
        guard id != 0, let current = currentDisplayID() else { return false }
        return current == id
    }

    /// Force a recompute now, for instance when the user enables the feature.
    /// Non-blocking.
    func prewarm() { requestRefresh() }

    /// Human-readable state for a log line or a diagnostics row.
    func diagnostics() -> String {
        os_unfair_lock_lock(lock)
        let snap = snapshot
        os_unfair_lock_unlock(lock)
        let age = snap.focusStamp == 0
            ? "never"
            : String(format: "%.0fms",
                     Double(DispatchTime.now().uptimeNanoseconds &- snap.focusStamp) / 1e6)
        let pointer = pointerDisplayID(in: snap.layout).map(String.init) ?? "nil"
        return "trusted=\(AXIsProcessTrusted()) focus=\(snap.focusID) age=\(age) "
             + "sticky=\(snap.stickyID) pointer=\(pointer) observing=\(observedPID)"
    }

    // MARK: - Lifecycle (main thread)

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true

        // Workspace notifications post only to the workspace centre, never to
        // NotificationCenter.default.
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(frontmostAppChanged(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(spaceChanged(_:)),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        wc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        CGDisplayRegisterReconfigurationCallback(activeDisplayReconfigCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())

        rebuildLayout()
        rearmObserver(for: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        requestRefresh()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started else { return }
        started = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        CGDisplayRemoveReconfigurationCallback(activeDisplayReconfigCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        tearDownObserver()
    }

    // MARK: - Invalidation sources

    @objc private func frontmostAppChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        rearmObserver(for: app?.processIdentifier ?? 0)
        requestRefresh()
    }

    @objc private func spaceChanged(_ note: Notification) { requestRefresh() }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let pid = app?.processIdentifier, pid == observedPID { tearDownObserver() }
        requestRefresh()
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        rebuildLayout()
        requestRefresh()
    }

    fileprivate func displaysReconfigured() {
        rebuildLayout()
        requestRefresh()
    }

    /// Called from the AXObserver callback and from the notification handlers.
    fileprivate func requestRefresh() {
        os_unfair_lock_lock(lock)
        let busy = snapshot.refreshInFlight
        if !busy { snapshot.refreshInFlight = true }
        os_unfair_lock_unlock(lock)
        guard !busy else { return }
        axQueue.async { [weak self] in self?.recomputeFocus() }
    }

    // MARK: - Display layout snapshot

    /// CGDisplayBounds and CGMainDisplayID cost tens of microseconds each with
    /// occasional multi-millisecond outliers, so the layout is snapshotted here
    /// instead of being queried per keypress.
    private func rebuildLayout() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }

        var boxes: [Box] = []
        boxes.reserveCapacity(Int(count))
        for id in ids.prefix(Int(count)) {
            // Collapse mirror slaves onto their master, because DisplayDiscovery
            // drops the slaves and so the bound id is always a master. Without
            // this, isActive(boundID) is false while the monitor is mirroring.
            let mirrorMaster = CGDisplayMirrorsDisplay(id)
            let effective = (mirrorMaster != 0 && mirrorMaster != id) ? mirrorMaster : id
            if boxes.contains(where: { $0.id == effective }) { continue }
            boxes.append(Box(id: effective, bounds: CGDisplayBounds(id)))
        }

        os_unfair_lock_lock(lock)
        snapshot.layout = boxes
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Pointer fallback

    /// `CGEvent(source: nil)?.location` is already in CG global top-left space,
    /// so no flip is needed, and unlike `NSEvent.mouseLocation` it is not an
    /// AppKit call and is safe off the main thread.
    private func pointerDisplayID(in layout: [Box]) -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        return Self.hitTest(point: point, in: layout)
    }

    private static func hitTest(point: CGPoint, in layout: [Box]) -> CGDirectDisplayID? {
        // CGRect.contains is half-open (minX <= x < maxX), so displays that abut
        // exactly never both claim a boundary point.
        for box in layout where box.bounds.contains(point) { return box.id }
        return nil
    }

    // MARK: - Accessibility walk (AX queue only, this blocks)

    private func recomputeFocus() {
        dispatchPrecondition(condition: .onQueue(axQueue))

        let resolved = resolveFocusedWindowDisplay()
        let stamp = DispatchTime.now().uptimeNanoseconds

        os_unfair_lock_lock(lock)
        snapshot.refreshInFlight = false
        snapshot.focusStamp = stamp
        switch resolved {
        case .display(let id):
            snapshot.focusID = id
            snapshot.stickyID = id
        case .selfApp:
            // MacQ's own popover or window is key. Do not let clicking the
            // status item drag the answer onto the menu-bar display, and do not
            // fall back to the pointer either (it is on the status item the user
            // just clicked). Keep the last display they were working on.
            snapshot.focusID = snapshot.stickyID
        case .unresolved:
            snapshot.focusID = 0
        }
        os_unfair_lock_unlock(lock)
    }

    private enum FocusResult {
        case display(CGDirectDisplayID)
        case selfApp
        case unresolved
    }

    private func resolveFocusedWindowDisplay() -> FocusResult {
        // Without Accessibility trust every AX call fails instantly with
        // kAXErrorAPIDisabled. The event tap needs the same grant, so in
        // practice this is only false during first-run onboarding.
        guard AXIsProcessTrusted() else { return .unresolved }

        guard let appElement = copyElement(systemWide, kAXFocusedApplicationAttribute) else {
            return .unresolved
        }

        var pid: pid_t = 0
        if AXUIElementGetPid(appElement, &pid) == .success, pid == selfPID { return .selfApp }
        AXUIElementSetMessagingTimeout(appElement, axTimeout)

        // AXFocusedWindow is the right question. AXMainWindow is the consolation
        // prize for apps that keep a main window but report no focused one.
        let window = copyElement(appElement, kAXFocusedWindowAttribute)
            ?? copyElement(appElement, kAXMainWindowAttribute)
        guard let window else { return .unresolved }
        guard let rect = windowFrame(window) else { return .unresolved }
        guard let id = displayID(forAXRect: rect) else { return .unresolved }
        return .display(id)
    }

    /// One round trip for both attributes instead of two, falling back to the
    /// separate reads for apps that do not implement the multiple-value call.
    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        var raw: CFArray?
        let attrs = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        let err = AXUIElementCopyMultipleAttributeValues(
            window, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        if err == .success, let values = raw as? [CFTypeRef], values.count == 2,
           let origin = cgPoint(values[0]), let size = cgSize(values[1]) {
            return CGRect(origin: origin, size: size)
        }
        return windowFrameSeparately(window)
    }

    private func windowFrameSeparately(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString,
                                            &posRef) == .success,
              let origin = cgPoint(posRef) else { return nil }

        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString,
                                            &sizeRef) == .success,
              let size = cgSize(sizeRef) else { return nil }

        return CGRect(origin: origin, size: size)
    }

    // MARK: - AX unwrapping

    // `value as? AXUIElement` and `value as? AXValue` warn "conditional downcast
    // to CoreFoundation type will always succeed" and do not actually check the
    // type, so these check CFGetTypeID first and then force-cast. The AXValue
    // type check also matters because a failed attribute inside
    // AXUIElementCopyMultipleAttributeValues comes back as an AXValue of type
    // kAXValueTypeAXError rather than as nil.

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func cgPoint(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func cgSize(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - Rect to display

    /// AX positions are documented as "0,0 is the top-left corner of the screen
    /// that displays the menu bar, +x right, +y down, units are points". That is
    /// exactly the CG global space CGDisplayBounds uses, so the rect needs NO
    /// conversion. Flipping it here is the single most likely bug in this file:
    /// it looks correct on a single-display Mac and breaks the moment the
    /// external monitor sits above or below the built-in one.
    private func displayID(forAXRect rect: CGRect) -> CGDirectDisplayID? {
        os_unfair_lock_lock(lock)
        let layout = snapshot.layout
        os_unfair_lock_unlock(lock)
        guard !layout.isEmpty else { return nil }

        // Preferred rule: the display containing the window's centre. A window
        // straddling two displays belongs to whichever holds most of it, and the
        // centre is the cheap, stable proxy: it does not flicker as the window is
        // nudged, and it matches where macOS sends the window when it zooms.
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        if let id = Self.hitTest(point: centre, in: layout) { return id }

        // The centre can miss, because displays need not tile the plane (an
        // L-shaped arrangement leaves gaps) and a window can be dragged mostly
        // offscreen. Fall back to the largest overlap, the exact rule the centre
        // was approximating.
        var best: CGDirectDisplayID = 0
        var bestArea: CGFloat = 0
        for box in layout {
            let overlap = box.bounds.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea { bestArea = area; best = box.id }
        }
        return best != 0 ? best : nil
    }

    // MARK: - AXObserver (main thread)

    private func rearmObserver(for pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard pid != observedPID || observer == nil else { return }
        tearDownObserver()
        guard pid > 0, pid != selfPID, AXIsProcessTrusted() else { return }

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, activeDisplayAXCallback, &newObserver) == .success,
              let newObserver else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Registration failing is normal, not exceptional: apps with partial AX
        // support return -25204/-25205/-25208. The TTL is the backstop.
        for name in [kAXFocusedWindowChangedNotification,
                     kAXMainWindowChangedNotification,
                     kAXWindowMiniaturizedNotification,
                     kAXWindowCreatedNotification] {
            _ = AXObserverAddNotification(newObserver, appElement, name as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(newObserver),
                           .defaultMode)

        observer = newObserver
        observedAppElement = appElement
        observedPID = pid

        // Window-level moves are registered separately, since some apps only
        // post them from the window element.
        refocusWindowObservations()
    }

    /// Re-point the window-level notifications after focus moved inside the app.
    fileprivate func refocusWindowObservations() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let observer, let appElement = observedAppElement else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        if let old = observedWindowElement {
            for name in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
                _ = AXObserverRemoveNotification(observer, old, name as CFString)
            }
            observedWindowElement = nil
        }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return }
        let windowElement = focusedRef as! AXUIElement
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
            _ = AXObserverAddNotification(observer, windowElement, name as CFString, refcon)
        }
        observedWindowElement = windowElement
    }

    private func tearDownObserver() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let observer {
            // Removing the run-loop source matters: without it MacQ leaks a
            // source on every app switch.
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
        observer = nil
        observedAppElement = nil
        observedWindowElement = nil
        observedPID = 0
    }
}

// MARK: - C callbacks

/// AXObserver notifications land here on the main run loop.
private func activeDisplayAXCallback(_ observer: AXObserver,
                                     _ element: AXUIElement,
                                     _ notification: CFString,
                                     _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let resolver = Unmanaged<ActiveDisplay>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    if name == kAXFocusedWindowChangedNotification || name == kAXMainWindowChangedNotification {
        resolver.refocusWindowObservations()
    }
    resolver.requestRefresh()
}

/// Display hotplug, mode and arrangement changes.
private func activeDisplayReconfigCallback(_ display: CGDirectDisplayID,
                                           _ flags: CGDisplayChangeSummaryFlags,
                                           _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let relevant: CGDisplayChangeSummaryFlags =
        [.addFlag, .removeFlag, .enabledFlag, .disabledFlag,
         .setModeFlag, .movedFlag, .desktopShapeChangedFlag]
    guard !flags.intersection(relevant).isEmpty else { return }
    let resolver = Unmanaged<ActiveDisplay>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { resolver.displaysReconfigured() }
}
