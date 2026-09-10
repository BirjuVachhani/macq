# Changelog

Notable changes to MacQ, newest first.

The entries here are what Sparkle shows in the update dialog: `make release`
lifts the section matching the version being built straight out of this file and
puts it in [the appcast](https://artifacts.birju.dev/macq/appcast.xml). Write
them for someone deciding whether to install the update, not for someone
reading the diff.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
MacQ aims at [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-09-05

### Added

- Power the monitor off and wake it again from the menu-bar popover.
- A toggle for the monitor's auto input detection, which now survives an input
  switch instead of being cleared by it.

### Changed

- Clearer wording throughout the popover when the monitor is not reachable over
  DDC, so a sleeping or disconnected display no longer looks like a bug.
- Tidier layout for the auto input detect row.

## [0.2.0] - 2026-08-16

### Added

- Media keys drive the monitor: volume, mute and brightness are routed to the
  display under the pointer rather than to the Mac's built-in output.
- A level indicator drawn to match macOS 26, hung under the menu-bar icon, with
  the monitor's name in its title.

### Fixed

- Brightness keys sent as key codes 144 and 145 are now intercepted, which is
  how several keyboards emit them.
- DDC calls are retried when the monitor is attached but not yet answering,
  which is the usual state for a second or two after waking.

### Changed

- Settings uses a segmented picker instead of a tab view.

## [0.1.0] - 2026-08-04

### Added

- First release: input switching, brightness and volume for BenQ
  displays over DDC/CI, from the menu bar.

[0.3.0]: https://github.com/BirjuVachhani/macq/releases/tag/0.3.0
[0.2.0]: https://github.com/BirjuVachhani/macq/releases/tag/0.2.0
[0.1.0]: https://github.com/BirjuVachhani/macq/releases/tag/0.1.0
