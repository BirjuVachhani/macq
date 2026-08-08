# MacQ

A lightweight macOS menu-bar controller for BenQ monitors: switch the input
source, set brightness and volume, without BenQ's 863 MB Display Pilot 2.

MacQ talks to the monitor with standard DDC/CI over IOKit, the same mechanism
Display Pilot 2 uses. The protocol, VCP codes and hardware quirks are documented
in [docs/benq-ddc-reference.md](docs/benq-ddc-reference.md).

## Features

- **Tiny memory footprint.** MacQ is a single native Swift process with no
  bundled browser runtime. Display Pilot 2 ships Qt and QtWebEngine, an embedded
  Chromium, and pays for it in resident memory.
- **Under 5 MB on disk.** The whole app bundle is about 4 MB, against Display
  Pilot 2's 863 MB, for the handful of controls you actually reach for.
- **Lives in your menu bar.** One click to open the popover, one click to change
  something, and it is out of your way again. MacQ shows a Dock icon only while
  a window is open and drops back to menu-bar-only when they all close.
- **Input switching.** The popover lists the monitor's video sources (USB-C,
  HDMI 1, HDMI 2) with the active one highlighted. Click one to switch the input
  (VCP `0x60`).
- **Aliases for input sources.** Rename each source per monitor (Settings >
  Sources) so the list reads "MacBook" and "Work PC" instead of "HDMI 1" and
  "HDMI 2". Names persist.
- **Brightness control** (VCP `0x10`) and **volume control** (VCP `0x62`, scaled
  to the maximum the monitor reports; the MA320UP reports 50). Both sliders
  update the display live, coalescing writes to about 20 per second during a drag
  and writing the final value on release, and appear only when the monitor
  advertises and answers that control.
- **Keyboard media keys, on the monitor.** The brightness (F1, F2) and volume
  (F10, F11, F12) keys drive the external monitor while it is the active display,
  the way Display Pilot 2 behaves. Click a window on the monitor and the keys
  change the monitor; go back to a window on the built-in display and they change
  the Mac again. Off by default, and it needs Accessibility permission. See
  [Keyboard media keys](#keyboard-media-keys).
- **Auto launch at startup.** A launch-at-login toggle (Settings > General), off
  by default, via `SMAppService`.
- **Honest about what it can drive.** MacQ detects the external monitor and gates
  every control on DDC/CI being available, with a manual "Sync now" to re-query
  the monitor.
- An onboarding window at launch explaining what MacQ does and where to find it.

On a MacBook with a notch, a crowded menu bar can hide new status items behind
the notch. If you do not see the icon, quit some other menu-bar apps or use a
menu-bar manager. The launch window is there so the app is always reachable.

## Keyboard media keys

Off by default. Turn it on in Settings > Keyboard.

With it on, MacQ intercepts the media keys before macOS sees them and applies
them to the external monitor over DDC/CI while that monitor is the active
display. "Active" means the display holding the focused window, falling back to
the display under the pointer when nothing is focused. Move focus to a window on
the built-in display and the keys reach macOS untouched, as usual.

- **Brightness** (F1, F2) follows the active display.
- **Volume** (F11, F12) and **mute** (F10, VCP `0x8D`) always require the monitor
  to be the current sound output device. MacQ matches the display to its
  DisplayPort audio device by EDID UUID and never writes the monitor's volume or
  mute while the Mac is playing somewhere else: that is inaudible at best, and on
  some panels it wakes their own speakers and their on-screen display. The rule
  in Settings only chooses whether the focused window is an extra requirement on
  top of that:
  - *Whenever sound is playing through the monitor*, the default. Whichever
    screen you are looking at, the keys go to the monitor while it is the
    selected output.
  - *Only while the monitor is also the active display*, for a desk where the
    monitor is the speaker but a lot of work happens on the built-in screen.
- Under either rule, a key that does not qualify passes straight through, so the
  Mac's own volume keeps responding normally.
- Intercepting a key also suppresses the system indicator, so MacQ draws its own
  level indicator on the monitor. That can be switched off too.

The same gate covers the popover's volume slider, not just the keys, so it is
dimmed while sound is coming from somewhere other than the monitor.

**Permission.** An intercepting event tap requires Accessibility (System Settings
> Privacy & Security > Accessibility), not Input Monitoring. MacQ inspects only
the brightness, volume and mute keys, and installs no tap at all until you enable
the feature.

**Limitation.** MacQ drives one external monitor at a time, the one it has bound
to. If a different external display is the active one, its keys are left to
macOS.

## Requirements

- **Apple Silicon Mac.** The DDC transport uses the `IOAVService` path. The Intel
  path is documented in the reference but not implemented.
- **macOS 14** or later.
- **Xcode 16** or later to build.
- **Accessibility permission**, but only if you enable the keyboard media keys.
  Nothing else in MacQ asks for a privacy grant.

Tested against a BenQ MA320UP. Other DDC-capable displays will partly work: the
transport is generic, but the input-source map is specific to the MA series (see
[BenQProfile.swift](app/MacQ/Core/BenQProfile.swift)).

## Build and run

`MacQ.xcodeproj` is a standard, self-contained Xcode project. No code generation,
no package manager, no extra tooling.

```sh
cd app
open MacQ.xcodeproj
```

Then Run (Cmd-R). Or from the command line:

```sh
cd app
xcodebuild -project MacQ.xcodeproj -scheme MacQ -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/MacQ.app
```

The project builds ad-hoc signed with no team, so it runs locally on any machine
without an Apple Developer account. MacQ launches with no Dock icon and no
window: look for the display icon in the menu bar.

## Releasing

The [Makefile](Makefile) builds, signs, notarizes and packages a distributable
DMG. It needs an Apple Developer account, since the `IOAVService` path does not
work under the App Store sandbox and therefore ships Developer ID signed and
notarized outside the App Store.

```sh
cp secrets/config.mk.example secrets/config.mk   # fill in signing identity + notary creds
make doctor                                      # check toolchain and config
make release                                     # build, sign, notarize, dmg, verify
```

`make help` lists every target. Signing material and credentials live in
[secrets/](secrets/README.md) and are excluded from version control.

## Architecture

```
App/
  main.swift            AppKit entry point (NSApplication + AppDelegate)
  AppDelegate.swift     Status item + popover, Settings window, Dock policy
UI/
  MenuContent.swift     The menu-bar popover (SwiftUI, hosted in an NSPopover)
  SettingsView.swift    Settings window (SwiftUI)
Core/
  DisplayController.swift  Orchestrator (ObservableObject); DDC on a serial queue,
                           @Published state on main; display-reconfig callback
  DisplayDiscovery.swift   Enumerate external displays, bind DDC transport
  Capabilities.swift       Parse the DDC/CI capabilities string
  BenQProfile.swift        Input value to label map, and the read/write asymmetry
  AliasStore.swift         Persist per-monitor source names (UserDefaults)
  Models.swift             ExternalDisplay, InputSource, ControlAvailability
  Preferences.swift        Media-key settings (UserDefaults), observable
  MediaKeyTap.swift        CGEvent tap over NX_SYSDEFINED: decode a media key,
                           swallow it or pass it on, re-arm after a timeout
  MediaKeyRouter.swift     Decides who owns a keypress and applies it
  ActiveDisplay.swift      Which display holds the focused window (Accessibility),
                           resolved out of band and cached; pointer as fallback
  AudioRouting.swift       Matches a display to its DisplayPort audio device by
                           EDID UUID, and tracks the default output device
  MediaKeyHUD.swift        Self-drawn level indicator (NSPanel) on the monitor
DDC/
  DDCShim.h / .m        Objective-C boundary over the private IOAVService and
                        CoreDisplay APIs; exposes a clean DDCLink to Swift
  DDC.swift             DDC/CI framing (getVCP / setVCP / capabilities) + retries
```

**Why an Objective-C shim:** the DDC transport uses private IOKit and CoreDisplay
symbols (`IOAVServiceCreate`, `IOAVServiceRead/WriteI2C`,
`CoreDisplay_DisplayCreateInfoDictionary`). Keeping CoreFoundation ownership in
Objective-C (ARC) avoids `Unmanaged` and CF-bridging friction in Swift.
Everything else is Swift.

**Why AppKit instead of SwiftUI's `MenuBarExtra`:** the `MenuBarExtra` scene
proved fragile here, receiving a teardown action from FrontBoardServices and
quitting the app at launch. An AppKit `NSStatusItem` with an `NSPopover` hosting
the SwiftUI views is the robust, conventional approach for a menu-bar app.

**Why a hand-drawn level indicator:** macOS has two private routes to the real
system indicator and neither is usable. `OSDUIHelper`, reached over XPC, still
renders on macOS 26, but what it renders is the pre-26 artifact: a 200x200
centred square with a 16-block meter, which is the look Tahoe replaced. The
genuine macOS 26 indicator is drawn by ControlCenter and is only reachable
through `OSD.framework`'s `OSDManager`, which is private, Swift-native on the
service side, silent rather than erroring when its protocol drifts, and addressed
by numeric graphic id (an unrecognised id is not harmless; one of them locks the
screen). So `MediaKeyHUD` draws the banner itself out of public AppKit:
`NSGlassEffectView` on macOS 26 and later, and the centred vibrancy square on
macOS 14 and 15, which is what those releases actually show. `NSGlassEffectView`
weak-links automatically at the macOS 14 deployment target, so the only cost is
an availability check.

## Testing input switching, carefully

Switching to an input with no live source stops the monitor from displaying the
Mac, and because DDC rides the USB-C DisplayPort link, the control channel can
disappear with it. Only the monitor's physical OSD buttons recover from that.
Confirm a source is live before switching to it, and keep the OSD buttons within
reach while testing.

MacQ selects USB-C by writing `0x13` (the OEM code, with `0x15` as a fallback)
and disables the panel's auto input switching (`0xF6`) first, because auto
switching otherwise reverts a manual selection. The full sequence and the reasons
behind each step are in the
[DDC reference](docs/benq-ddc-reference.md#input-source-0x60).

## Contributing

Issues and pull requests are welcome. Useful context before changing the DDC
layer: reads fail routinely and are retried, writes during a drag are coalesced,
and the input-source read and write values genuinely differ on this hardware.
All three are explained in the [DDC reference](docs/benq-ddc-reference.md).

## License

MIT. See [LICENSE](LICENSE).

MacQ is an independent project, not affiliated with or endorsed by BenQ. The
protocol details were reverse-engineered for interoperability and validated
against real hardware.
