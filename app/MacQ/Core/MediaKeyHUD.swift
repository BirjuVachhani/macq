//
//  MediaKeyHUD.swift
//  MacQ
//
//  The on-screen level indicator shown when a media key drives the external
//  monitor instead of the Mac.
//
//  Swallowing a media key also swallows the system indicator, so without this
//  the key would appear to do nothing on the panels where the change is subtle.
//  MacQ therefore draws its own.
//
//  WHY NOT THE SYSTEM INDICATOR
//    Two private paths exist and neither is usable. OSDUIHelper, reached over
//    XPC, does still render on macOS 26, but what it renders is the pre-26
//    artifact: a 200x200 centred square with a 16-block chiclet meter. Adopting
//    it would ship exactly the look this file exists to avoid. The genuine
//    macOS 26 indicator is drawn by ControlCenter as a "system banner" and is
//    only reachable through OSD.framework's OSDManager: private, Swift-native
//    on the service side, silent when its protocol drifts, and addressed by
//    numeric graphic id, where an unrecognised id is not harmless (one of them
//    locks the screen). So MacQ draws the banner itself, out of public AppKit.
//
//  ERAS
//    macOS 26 and later: a Liquid Glass banner anchored under the menu bar at
//    the trailing edge, with a continuous level track. NSGlassEffectView is
//    public from 26.0 and weak-links automatically at this deployment target,
//    so the only cost is the availability check.
//    macOS 14 and 15: the centred vibrancy square with a 16-segment meter,
//    which is what those releases actually show.
//
//  Main thread only, matching its call site inside the event-tap callback.
//

import AppKit

final class MediaKeyHUD {

    static let shared = MediaKeyHUD()

    /// What the glyph should show. The level is always drawn.
    enum Glyph {
        case brightness
        case volume
        case muted

        var symbolName: String {
            switch self {
            case .brightness: return "sun.max.fill"
            case .volume: return "speaker.wave.3.fill"
            case .muted: return "speaker.slash.fill"
            }
        }
    }

    // MARK: - Tuning

    /// Everything below that differs between the two eras is keyed off this one
    /// flag, so there is a single place to reason about which HUD is in play.
    private static let usesBanner: Bool = {
        if #available(macOS 26.0, *) { return true }
        return false
    }()

    // Banner, macOS 26 and later.
    //
    // The height and radius are a capsule: 44 tall, radius 22. The insets place
    // it under the menu bar at the trailing edge, where macOS 26 puts its own.
    // Measured context, not guesses about the system banner's own art: the menu
    // bar is 33.0 pt on the built-in display (NSScreen.frame.maxY minus
    // visibleFrame.maxY) and 0 on the external panel, which is why the vertical
    // anchor is taken from visibleFrame instead of from a constant. The system
    // banner's exact art has not been measured, so these are a visual match and
    // are expected to be nudged once someone captures it side by side.
    private static let bannerSize = CGSize(width: 196, height: 44)
    private static let bannerCornerRadius: CGFloat = 22
    private static let bannerEdgeInset: CGFloat = 12
    private static let bannerTopInset: CGFloat = 6
    private static let bannerGlyphSize: CGFloat = 20
    private static let bannerGlyphPointSize: CGFloat = 15
    private static let bannerLeadingInset: CGFloat = 16
    private static let bannerTrailingInset: CGFloat = 16
    private static let bannerGlyphToTrackGap: CGFloat = 12

    // Legacy, macOS 14 and 15. These are measurements of the real pre-26 HUD:
    // 200x200, horizontally centred, exactly 140.0 pt above the bottom edge of
    // the display, and an 18 pt CIRCULAR corner (not .continuous, which is
    // about 6% too much corner area).
    private static let legacySize = CGSize(width: 200, height: 200)
    private static let legacyCornerRadius: CGFloat = 18
    private static let legacyBottomInset: CGFloat = 140
    private static let legacyGlyphPointSize: CGFloat = 68
    /// Segment count in the legacy meter. 16 matches both the pre-26 system
    /// indicator and the 1/16-of-range step MacQ applies per keypress, so one
    /// press moves exactly one segment.
    private static let legacySegments = 16

    /// ControlCenter's own OSD requests log msecUntilFade: 4000. Four seconds of
    /// a third-party panel sitting over the user's content is more intrusive
    /// than informative, so MacQ holds it for two and fades a little faster.
    private let visibleDuration: TimeInterval = 2.0
    private let fadeOutDuration: TimeInterval = 0.3

    // MARK: - State

    private var panel: NSPanel?
    private var glyphView: NSImageView?
    private var levelView: LevelView?
    private var hideGeneration = 0

    private init() {}

    // MARK: - API

    /// Shows the indicator on `displayID` at `value`/`maximum`.
    ///
    /// Cheap to call repeatedly: the window is built once and reused, and a
    /// repeat while it is already visible only updates the level and restarts
    /// the dismissal timer.
    func show(_ glyph: Glyph, value: Int, maximum: Int, on displayID: CGDirectDisplayID) {
        dispatchPrecondition(condition: .onQueue(.main))

        let panel = ensurePanel()
        glyphView?.image = symbol(for: glyph)
        levelView?.fraction = min(1, max(0, Double(value) / Double(max(1, maximum))))

        position(panel, on: displayID)

        // orderFrontRegardless, not orderFront: MacQ is usually not the active
        // app when a media key is pressed, and orderFront does nothing for an
        // inactive app.
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        // A zero-duration animation on the same property, rather than a plain
        // assignment: it replaces any fade already in flight. Assigning directly
        // would be overwritten by the remaining frames of that fade, so a key
        // pressed during dismissal would keep fading out.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }

        scheduleHide()
    }

    /// Hides immediately, for instance when the feature is switched off.
    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        hideGeneration &+= 1
        panel?.orderOut(nil)
    }

    // MARK: - Dismissal

    /// Generation counter rather than a retained Timer, so a rapid key repeat
    /// simply invalidates the previous pending dismissal.
    private func scheduleHide() {
        hideGeneration &+= 1
        let generation = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration) { [weak self] in
            guard let self, self.hideGeneration == generation, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = self.fadeOutDuration
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // Re-check: another keypress during the fade bumps the counter
                // and has already set alpha back to 1.
                guard let self, self.hideGeneration == generation else { return }
                panel.orderOut(nil)
            }
        }
    }

    // MARK: - Window

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let size = Self.usesBanner ? Self.bannerSize : Self.legacySize

        // .nonactivatingPanel is the load-bearing flag: without it, ordering the
        // window in from a background app steals focus from whatever the user is
        // actually working in.
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // .screenSaver clears the Dock, the menu bar and full-screen windows.
        // The real system indicator sits higher, at CGWindowLevel 2005, but the
        // login window's shield sits at 1999 to 2001, so matching 2005 would put
        // MacQ's level bar on top of a LOCKED screen. Staying at 1000 is a
        // deliberate deviation from the system, not an oversight.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        // Excluded from window cycling and from screenshots of "windows".
        panel.isExcludedFromWindowsMenu = true

        let glyph = NSImageView()
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .labelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *), Self.usesBanner {
            let level = BannerLevelView()
            level.translatesAutoresizingMaskIntoConstraints = false

            let content = NSView(frame: CGRect(origin: .zero, size: size))
            content.autoresizingMask = [.width, .height]
            content.addSubview(glyph)
            content.addSubview(level)

            NSLayoutConstraint.activate([
                glyph.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                               constant: Self.bannerLeadingInset),
                glyph.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: Self.bannerGlyphSize),
                glyph.heightAnchor.constraint(equalToConstant: Self.bannerGlyphSize),

                level.leadingAnchor.constraint(equalTo: glyph.trailingAnchor,
                                               constant: Self.bannerGlyphToTrackGap),
                level.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                constant: -Self.bannerTrailingInset),
                level.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                level.heightAnchor.constraint(equalToConstant: BannerLevelView.trackHeight),
            ])

            let glass = NSGlassEffectView(frame: CGRect(origin: .zero, size: size))
            glass.autoresizingMask = [.width, .height]
            // cornerRadius belongs to the glass view, NOT to its layer. The
            // radius takes part in the signed-distance field the effect renders,
            // so rounding the layer by hand (the way the legacy panel below has
            // to) clips the lensing and leaves the glass itself square.
            glass.cornerRadius = Self.bannerCornerRadius
            // nil keeps the system's own glass tint. A colour here would make
            // the panel read as a MacQ widget rather than as a system indicator.
            glass.tintColor = nil
            // Only `contentView` is documented to sit inside the glass; anything
            // added as a plain subview has undefined z-order against the effect.
            glass.contentView = content

            panel.contentView = glass
            self.levelView = level
        } else {
            let level = ChicletLevelView(segments: Self.legacySegments)
            level.translatesAutoresizingMaskIntoConstraints = false

            let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.legacyCornerRadius
            // .circular, not .continuous: the pre-26 HUD's corner measures
            // 72.06 pt^2 of transparency, which is circular r=18 (72.12) and not
            // continuous r=18 (76.34).
            effect.layer?.cornerCurve = .circular
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            effect.addSubview(glyph)
            effect.addSubview(level)

            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: effect.centerYAnchor, constant: 14),
                glyph.widthAnchor.constraint(equalToConstant: 88),
                glyph.heightAnchor.constraint(equalToConstant: 88),

                level.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
                level.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -26),
                level.widthAnchor.constraint(
                    equalToConstant: ChicletLevelView.width(for: Self.legacySegments)),
                level.heightAnchor.constraint(equalToConstant: ChicletLevelView.barHeight),
            ])

            panel.contentView = effect
            self.levelView = level
        }

        self.panel = panel
        self.glyphView = glyph
        return panel
    }

    private func symbol(for glyph: Glyph) -> NSImage? {
        let pointSize = Self.usesBanner ? Self.bannerGlyphPointSize : Self.legacyGlyphPointSize
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(systemSymbolName: glyph.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Places the panel where that release's system indicator sits.
    ///
    /// NSScreen.frame is AppKit's bottom-left global space, not the top-left
    /// space CGDisplayBounds uses, so the display is looked up through NSScreen
    /// rather than converted by hand.
    private func position(_ panel: NSPanel, on displayID: CGDirectDisplayID) {
        let screen = Self.screen(for: displayID) ?? NSScreen.screens.first
        guard let screen else { return }

        let frame: CGRect
        if Self.usesBanner {
            // Top-trailing corner of the usable area. visibleFrame already has
            // the menu bar taken out on whichever display owns it, and equals
            // the full frame on a display that has none, so a single expression
            // covers both the built-in screen and the external panel.
            let area = screen.visibleFrame
            frame = CGRect(x: area.maxX - Self.bannerSize.width - Self.bannerEdgeInset,
                           y: area.maxY - Self.bannerSize.height - Self.bannerTopInset,
                           width: Self.bannerSize.width,
                           height: Self.bannerSize.height)
        } else {
            frame = CGRect(x: screen.frame.midX - Self.legacySize.width / 2,
                           y: screen.frame.minY + Self.legacyBottomInset,
                           width: Self.legacySize.width,
                           height: Self.legacySize.height)
        }
        panel.setFrame(frame, display: false)
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }
}

// MARK: - Level views

/// Shared base so `show` sets one number and does not branch on the era.
private class LevelView: NSView {

    /// 0...1. Both meters redraw themselves from this and nothing else.
    var fraction: Double = 0 {
        didSet {
            guard abs(fraction - oldValue) > 0.0001 else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MediaKeyHUD's level views are created in code only, never from a nib.")
    }
}

/// macOS 26: one continuous capsule track, the way the system banner draws it.
private final class BannerLevelView: LevelView {

    static let trackHeight: CGFloat = 8

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2

        NSColor.labelColor.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard fraction > 0 else { return }
        // A fill narrower than the track becomes a squashed lozenge, so the fill
        // never goes below one track height: at the lowest non-zero step the
        // indicator reads as a dot rather than as a sliver.
        let width = max(bounds.height, bounds.width * CGFloat(fraction))
        let filled = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// macOS 14 and 15: the 16-block meter. Drawn rather than composed from
/// subviews so a level change is one setNeedsDisplay instead of 16 layer
/// mutations.
private final class ChicletLevelView: LevelView {

    static let segmentWidth: CGFloat = 7
    static let segmentGap: CGFloat = 2
    static let barHeight: CGFloat = 8

    static func width(for segments: Int) -> CGFloat {
        CGFloat(segments) * segmentWidth + CGFloat(max(0, segments - 1)) * segmentGap
    }

    private let segments: Int

    init(segments: Int) {
        self.segments = segments
        super.init(frame: .zero)
    }

    override func draw(_ dirtyRect: NSRect) {
        let filled = min(segments, max(0, Int((fraction * Double(segments)).rounded())))
        let on = NSColor.labelColor
        let off = NSColor.labelColor.withAlphaComponent(0.22)
        var x: CGFloat = 0
        for index in 0..<segments {
            let rect = NSRect(x: x, y: 0, width: Self.segmentWidth, height: bounds.height)
            (index < filled ? on : off).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            x += Self.segmentWidth + Self.segmentGap
        }
    }
}
