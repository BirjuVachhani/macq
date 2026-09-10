//
//  UpdaterController.swift
//  MacQ
//
//  Sparkle glue: owns the updater, exposes it to SwiftUI, and keeps a
//  menu-bar-only app visible while Sparkle has something to say.
//
//  The feed lives at SUFeedURL in Info.plist and is signed with the EdDSA key
//  whose public half is SUPublicEDKey. Sparkle refuses an update that is not
//  signed by that key, so a compromised host still cannot ship code here.
//
//  MacQ is a menu-bar app that is rarely quit, so a check that only happens at
//  launch would never happen. Two things run instead:
//
//    - a check at every launch, whatever the user's preference (see `start()`)
//    - hourly scheduled checks while "Check for updates automatically" is on,
//      driven by Sparkle from SUScheduledCheckInterval
//
//  Neither one puts a window in front of anyone. A scheduled check that finds
//  something sets `availableVersion` and stops there, which is Sparkle's
//  "gentle reminder" pattern; the popover and the main window turn that into an
//  "Update to latest version" row the user can take or ignore. Sparkle's own
//  update window appears only for a check the user asked for, including one
//  started by tapping that row.
//

import AppKit
import Combine
import Sparkle

/// Wraps `SPUStandardUpdaterController` so the rest of the app can drive
/// updates without importing Sparkle, and so SwiftUI can observe whether a
/// check is currently possible.
///
/// One instance, created at launch: Sparkle begins its update schedule as soon
/// as the controller is constructed, so tearing it down and rebuilding it per
/// window would restart that schedule each time.
final class UpdaterController: NSObject, ObservableObject {
    static let shared = UpdaterController()

    /// Nil until `start()` runs. Sparkle begins its update schedule as soon as
    /// the controller is constructed, so construction is deferred to
    /// `applicationDidFinishLaunching` rather than happening at `shared` access.
    private var controller: SPUStandardUpdaterController?

    /// False while a check is already running, and before `start()`. Bound to
    /// the enabled state of every "Check for updates" affordance.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates`. Sparkle persists this
    /// in UserDefaults itself; the published copy exists so a SwiftUI toggle can
    /// bind to it. The default is on, from SUEnableAutomaticChecks in Info.plist.
    ///
    /// This governs the hourly schedule only. The launch check ignores it, on
    /// the grounds that it costs one request, shows nothing unless there is
    /// news, and is the only check an app that is never quit would otherwise
    /// get.
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            // Sparkle resets its own schedule shortly after this is written, so
            // switching the toggle on does not wait an hour to take effect.
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published private(set) var lastCheckDate: Date?

    /// The version waiting to be installed, or nil when MacQ is up to date.
    ///
    /// Set by a check that found something, and cleared once the user installs
    /// or skips it, or a later check proves MacQ is current. "Remind Me Later"
    /// deliberately keeps it: the UI remains the gentle reminder the user
    /// chose to return to. The row appears exactly while this is non-nil.
    @Published private(set) var availableVersion: String?

    var isUpdateAvailable: Bool { availableVersion != nil }

    /// Whether a user action can start a check or bring a gently deferred
    /// update into focus. Sparkle briefly holds this false while handing a
    /// scheduled result to the custom reminder, then restores it once
    /// `checkForUpdates()` can safely bring that result into focus.
    var canActOnUpdates: Bool { canCheckForUpdates }

    /// How often the scheduled check runs, for display in Settings. Read from
    /// the updater so it cannot drift from what Sparkle is actually doing.
    var checkIntervalHours: Int {
        guard let updater = controller?.updater else { return 1 }
        return max(1, Int((updater.updateCheckInterval / 3600).rounded()))
    }

    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
    }

    /// Starts the updater. Safe to call more than once; only the first call
    /// builds the controller.
    func start() {
        guard controller == nil else { return }

        // startingUpdater: true begins the scheduled-check timer immediately.
        // The delegates are this object so the app can raise itself out of
        // accessory mode before Sparkle puts a window on screen, and so
        // scheduled updates arrive as a badge rather than a window.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller

        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        lastCheckDate = updater.lastUpdateCheckDate

        // canCheckForUpdates is KVO-compliant and flips for the whole duration
        // of a check, which is exactly the window a menu item should be greyed.
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: \.canCheckForUpdates, on: self)
            .store(in: &cancellables)

        checkOnLaunch(updater)
    }

    /// One silent check per launch, whichever way the preference is set.
    ///
    /// Which call does it depends on the preference, because the two are not
    /// interchangeable. `checkForUpdatesInBackground()` is the call Sparkle
    /// documents for forcing a launch check, and it opens a real update session
    /// that the "Update to latest version" row can bring straight into focus,
    /// but Sparkle asks that it only be used while automatic checks are on.
    /// With them off, `checkForUpdateInformation()` probes the feed without
    /// opening a session or touching the user driver: enough to light up the
    /// badge, and no part of the machinery the user opted out of.
    ///
    /// Both must run immediately after the updater starts. Later on they would
    /// interfere with Sparkle's own scheduler.
    private func checkOnLaunch(_ updater: SPUUpdater) {
        if automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        } else {
            updater.checkForUpdateInformation()
        }
    }

    /// User-initiated check. Always reports its result, including "you are up to
    /// date", unlike the scheduled check which stays silent when there is
    /// nothing to say.
    ///
    /// Also what the "Update to latest version" row calls: when a scheduled
    /// check has already found something, this brings that update's window into
    /// focus rather than starting over.
    func checkForUpdates() {
        guard let controller else { return }
        activateForUpdateUI()
        controller.checkForUpdates(nil)
    }

    /// A menu-bar app spends most of its life in `.accessory`, where a freshly
    /// ordered window opens behind whatever the user is actually looking at.
    /// Sparkle's alerts are worth interrupting for, so the app becomes a regular
    /// app for as long as one is on screen.
    private func activateForUpdateUI() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterController: SPUUpdaterDelegate {
    /// Fires for every kind of check: launch, scheduled, user-initiated, and
    /// the informational probe. This one callback is what keeps the badge in
    /// step with reality regardless of which path found the update.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
    }

    /// Keep the custom reminder for "Remind Me Later", but retire it once the
    /// user installs or explicitly skips this version. A skip must not leave a
    /// row for an update Sparkle has promised not to offer automatically again.
    func updater(_ updater: SPUUpdater,
                 userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .install || choice == .skip {
            availableVersion = nil
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastCheckDate = updater.lastUpdateCheckDate
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdaterController: SPUStandardUserDriverDelegate {
    /// Lets Sparkle hand scheduled updates over rather than pushing a window in
    /// front of the user unannounced.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// No: MacQ shows scheduled updates itself, as a row in the popover and the
    /// main window. An hourly check that could raise a window over whatever the
    /// user is doing is not worth having, and this is the only reason the
    /// interval can be as short as an hour.
    ///
    /// User-initiated checks never reach here; Sparkle always handles those.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    /// With the above returning false, `handleShowingUpdate` is false for a
    /// scheduled update and MacQ owns the reminder. `didFindValidUpdate` has
    /// already set the badge; this exists to catch the case where Sparkle
    /// reports an update it will not show through that path.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        if handleShowingUpdate {
            activateForUpdateUI()
        }
    }

    func standardUserDriverWillShowModalAlert() {
        activateForUpdateUI()
    }

    /// Sparkle is done talking, so drop back to menu-bar-only unless the user
    /// has one of MacQ's own windows open. AppDelegate owns that decision.
    func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.updateActivationPolicy()
        }
    }
}
