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
- **Keyboard media keys, on the monitor.** The brightness keys (F1, F2) change
  whichever screen the mouse pointer is on, and the volume keys (F10, F11, F12)
  change the monitor while it is the sound output device. Both are the rules
  Display Pilot 2 ships. Move the pointer onto the monitor and F1/F2 dim the
  monitor; move it back to the built-in screen and they dim the Mac. Off by
  default, and it needs Accessibility permission. See
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
them to the external monitor over DDC/CI. A key that does not qualify is never
touched, so the Mac keeps behaving normally.

- **Brightness** (F1, F2) follows the mouse pointer: the keys change whichever
  screen the pointer is currently on. This is exactly what Display Pilot 2 does
  (its own settings text reads "Controlling the monitor brightness depends on the
  mouse cursor position"), and it is instant, needs no permission of its own and
  is never ambiguous about which screen you meant. Focused-window tracking is
  kept only as a fallback for the moment the pointer is not over any display
  MacQ knows about, such as mid-reconfiguration.
- **Volume** (F11, F12) and **mute** (F10, VCP `0x8D`) always require the monitor
  to be the current sound output device. MacQ matches the display to its
  DisplayPort audio device by EDID UUID and never writes the monitor's volume or
  mute while the Mac is playing somewhere else: that is inaudible at best, and on
  some panels it wakes their own speakers and their on-screen display. Display
  Pilot 2 draws the same line, describing its volume keys as acting on "the
  selected audio output". The rule in Settings only chooses whether the pointer
  is an extra requirement on top of that:
  - *Whenever sound is playing through the monitor*, the default. Wherever the
    pointer is, the keys go to the monitor while it is the selected output.
  - *Only while the monitor is also the active display*, for a desk where the
    monitor is the speaker but a lot of work happens on the built-in screen.
- Under either rule, a key that does not qualify passes straight through, so the
  Mac's own volume keeps responding normally.
- Intercepting a key also suppresses the system indicator, so MacQ draws its own.
  It hangs under MacQ's menu-bar icon and is titled with the monitor it changed,
  which is what tells you the key went to the monitor rather than to the Mac. If
  the icon is hidden, the indicator falls back to the top right corner under the
  menu bar. It can be switched off too.

This rule governs the keys only. The popover's volume slider always drives the
monitor, whatever the Mac happens to be playing through, because dragging it is
an explicit instruction about that panel.

**Permission.** An intercepting event tap requires Accessibility (System Settings
> Privacy & Security > Accessibility), not Input Monitoring. MacQ installs no tap
at all until you enable the feature.

**What the tap sees.** Volume and mute arrive as classic media keys, on a stream
that carries nothing else. Brightness does not: on most keyboards, including this
Mac's own, the brightness keys are sent as ordinary key presses with key codes
144 and 145. Reading them therefore means watching the same stream every other
keystroke travels on, which is worth being plain about. The tap reads one thing
from each event, which key it was, and returns immediately for anything that is
not brightness, volume or mute. Nothing you type is inspected further, kept,
written to disk, or sent anywhere, and MacQ makes no network connections at all.

**Limitation.** MacQ drives one external monitor at a time, the one it has bound
to. If a different external display is the active one, its keys are left to
macOS.

**Waking.** A monitor is back in the display list before its DDC channel will
answer, so the reconfiguration event that prompts MacQ to re-query it often
arrives too early. When the monitor is present but silent, MacQ asks again after
1.5 s, 3 s and 6 s, rebuilding the DDC link each time, then stops and waits for
the next display change or a manual "Sync now". Without that, one badly timed
read after a wake would leave the monitor looking connected while every media key
quietly passed through to the Mac.

**Diagnostics.** Settings > Keyboard ends with a live log of every media key MacQ
sees and where it sent it, plus the display it currently considers active. A key
that produces no line at all never reached MacQ, which is a different fault from
one that reached MacQ and was passed to the Mac on purpose, and both differ again
from a tap that was never installed. Keypresses are recorded while that tab is
open; the tap's own lifecycle is recorded always, so an empty log still says
whether the tap is armed.

The same log can be written to a file, which is the better instrument for the
brightness keys: opening the settings window to read the log puts the pointer on
that window, and the pointer is what those keys follow.

```sh
defaults write dev.birjuvachhani.macq debugKeyLog -bool YES   # then relaunch MacQ
tail -f ~/Library/Logs/MacQ/mediakeys.log
```

It is truncated at each launch and holds nothing but the five media keys, the
routing decision for each, and the tap's lifecycle.

**A build from Xcode is a different app to macOS.** The Debug configuration uses
the bundle identifier `dev.birjuvachhani.macq-debug232`, which is both a separate
preferences domain (so every setting, including the media-keys switch, starts at
its default of off) and a separate Accessibility identity (so the grant given to
the release build does not apply). If the media keys appear dead in a build run
from Xcode, check that first: the log's `start:` line names the bundle identifier
it is actually using.

## Requirements

- **Apple Silicon Mac.** The DDC transport uses the `IOAVService` path. The Intel
  path is documented in the reference but not implemented.
- **macOS 14** or later to run.
- **Xcode 26** or later to build. The macOS 26 media-key indicator calls
  `NSGlassEffectView`, which only exists in the macOS 26 SDK. `#available` gates
  it at runtime, so the app still runs on macOS 14, but the call has to compile.
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
  MediaKeyTap.swift        CGEvent tap over NX_SYSDEFINED (volume, mute) and
                           key codes 144/145 (brightness): decode a key, swallow
                           it or pass it on, re-arm after a timeout
  MediaKeyRouter.swift     Decides who owns a keypress and applies it
  ActiveDisplay.swift      Which display is active: the one under the pointer,
                           with focused-window tracking (Accessibility) as a
                           fallback, resolved out of band and cached
  AudioRouting.swift       Matches a display to its DisplayPort audio device by
                           EDID UUID, and tracks the default output device
  MediaKeyHUD.swift        Self-drawn level indicator (NSPanel), titled with the
                           monitor's name and hung under the menu-bar icon
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
weak-links automatically at the macOS 14 deployment target, so the runtime cost
is one availability check. The build cost is less forgiving: `#available` decides
what runs, not what compiles, so the macOS 26 SDK is required to build at all.
That is why the requirement above is Xcode 26 and why the release workflow pins
its runner.

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
