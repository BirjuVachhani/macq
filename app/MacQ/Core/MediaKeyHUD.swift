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
//    macOS 26 and later: a Liquid Glass banner naming the monitor, with a
//    continuous level track and a knob, flanked by a quiet and an emphatic copy
//    of the symbol. Its appearance is left alone so the glass adapts, which is
//    the whole point of the material.
//    It hangs under MacQ's own menu-bar icon so the change
//    appears where the app that made it lives. When that icon is not on screen,
//    hidden by the user or by a menu-bar manager, or pushed off a crowded bar,
//    it falls back to the trailing edge under the menu bar, where macOS 26 puts
//    its own. NSGlassEffectView is public from 26.0 and weak-links
//    automatically at this deployment target, so the only cost is the
//    availability check.
//    macOS 14 and 15: the centred vibrancy square with a 16-segment meter,
//    which is what those releases actually show. That path is left as the
//    replica it is: neither the title nor the menu-bar anchor appears there,
//    since both are macOS 26 idioms and the point of that code is to look like
//    its own era.
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

        /// The low end of the range, drawn small before the track.
        ///
        /// The banner flanks its slider with two copies of the symbol rather
        /// than labelling it, a quiet one at the low end and an emphatic one at
        /// the high end, which is what tells you the bar is a range and which
        /// way it runs. The system banner does the same.
        var leadingSymbolName: String {
            switch self {
            case .brightness: return "sun.min.fill"
            case .volume: return "speaker.fill"
            case .muted: return "speaker.slash.fill"
            }
        }

        /// The high end, drawn larger after the track.
        var trailingSymbolName: String {
            switch self {
            case .brightness: return "sun.max.fill"
            case .volume, .muted: return "speaker.wave.3.fill"
            }
        }

        /// The legacy HUD draws one large glyph in the middle instead of a pair.
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
    // Two rows: the monitor's name, then the level track flanked by the quiet
    // and emphatic copies of the symbol. The name earns its place because the
    // banner no longer appears on the screen it is changing. It hangs under
    // MacQ's menu-bar icon, which is often on the other display, so without a
    // title the banner would not say what it just changed. macOS names the
    // display in its own brightness overlay for the same reason.
    //
    // These are measured off a 2x capture of the macOS 26 volume banner rather
    // than guessed: 293 x 71 pt overall, a 24 pt corner, an 18 pt inset at both
    // ends, the title's centre 21 pt below the top edge, and the slider row's
    // centre 24 pt above the bottom edge. Rounded to whole points below.
    //
    // Separately measured on this Mac, and the reason the vertical anchor comes
    // from visibleFrame rather than a constant: the menu bar is 33.0 pt on the
    // built-in display (NSScreen.frame.maxY minus visibleFrame.maxY) and 0 on
    // the external panel.
    private static let bannerHeight: CGFloat = 72
    private static let bannerCornerRadius: CGFloat = 24
    private static let bannerEdgeInset: CGFloat = 12
    private static let bannerLeadingInset: CGFloat = 18
    private static let bannerTrailingInset: CGFloat = 18
    private static let bannerTitleTopInset: CGFloat = 13
    /// Centre of the slider row, measured up from the banner's bottom edge.
    private static let bannerRowCentreFromBottom: CGFloat = 24
    private static let bannerGlyphToTrackGap: CGFloat = 10
    private static let bannerLeadingGlyphSize: CGFloat = 14
    private static let bannerLeadingGlyphPointSize: CGFloat = 11
    private static let bannerTrailingGlyphSize: CGFloat = 20
    private static let bannerTrailingGlyphPointSize: CGFloat = 16
    private static let bannerTitleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    /// Gap between whatever the banner hangs from (the menu bar, or the icon in
    /// it) and the top of the banner.
    private static let bannerMenuBarGap: CGFloat = 6

    /// The banner's width, chosen from the title and clamped.
    ///
    /// A fixed width would truncate a long display name that had room to spare,
    /// so the width follows the name between two bounds. The lower bound is the
    /// system banner's own width, which is what a short name like "BenQ
    /// MA320UP" gets: shrinking to fit it would leave the slider stunted and
    /// stop the banner reading as the thing it stands in for. The upper bound
    /// stops a verbose name growing a banner across the screen; past it, the
    /// label truncates instead.
    private static let bannerMinWidth: CGFloat = 292
    private static let bannerMaxWidth: CGFloat = 380

    private static func bannerSize(for title: String) -> CGSize {
        let measured = (title as NSString)
            .size(withAttributes: [.font: bannerTitleFont]).width.rounded(.up)
        let width = min(bannerMaxWidth,
                        max(bannerMinWidth,
                            measured + bannerLeadingInset + bannerTrailingInset))
        return CGSize(width: width, height: bannerHeight)
    }

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
    /// The legacy HUD's single central glyph. Nil on the banner path.
    private var glyphView: NSImageView?
    /// The banner's flanking pair. Both nil on the legacy path.
    private var leadingGlyphView: NSImageView?
    private var trailingGlyphView: NSImageView?
    private var titleField: NSTextField?
    private var levelView: LevelView?
    private var hideGeneration = 0
    private var lastPlacement: String?

    /// Where MacQ's menu-bar icon is, in screen coordinates, or nil when there
    /// is no icon on screen to hang the banner from.
    ///
    /// A closure rather than a reference to the NSStatusItem: this file draws an
    /// indicator and has no business knowing how the app builds its menu bar.
    /// AppDelegate installs it once the status item exists, and it is asked
    /// again on every show, because the icon shifts whenever another menu-bar
    /// app comes or goes and follows the menu bar between displays.
    var menuBarAnchor: (() -> CGRect?)?

    private init() {}

    // MARK: - API

    /// Shows the indicator for `title` at `value`/`maximum`.
    ///
    /// `displayID` is the monitor being changed. It chooses the screen only in
    /// the fallback placement: when MacQ's menu-bar icon is on screen the banner
    /// hangs under that instead, wherever it happens to be, which is exactly why
    /// the banner has to name the monitor.
    ///
    /// Cheap to call repeatedly: the window is built once and reused, and a
    /// repeat while it is already visible only updates the level and restarts
    /// the dismissal timer.
    func show(_ glyph: Glyph, title: String, value: Int, maximum: Int,
              on displayID: CGDirectDisplayID) {
        dispatchPrecondition(condition: .onQueue(.main))

        let panel = ensurePanel()
        if Self.usesBanner {
            leadingGlyphView?.image = symbol(named: glyph.leadingSymbolName,
                                             pointSize: Self.bannerLeadingGlyphPointSize)
            trailingGlyphView?.image = symbol(named: glyph.trailingSymbolName,
                                              pointSize: Self.bannerTrailingGlyphPointSize)
        } else {
            glyphView?.image = symbol(named: glyph.symbolName,
                                      pointSize: Self.legacyGlyphPointSize)
        }
        titleField?.stringValue = title
        levelView?.fraction = min(1, max(0, Double(value) / Double(max(1, maximum))))

        position(panel, title: title, on: displayID)

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

        // A placeholder size. Every show re-measures the banner against the
        // title it is about to draw and sets the real frame in `position`.
        let size = Self.usesBanner ? Self.bannerSize(for: "") : Self.legacySize

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
        // Glass floats above what it is refracting, and the drop shadow is part
        // of how it reads as a separate pane of material rather than as a tinted
        // patch of the wallpaper. The pre-26 chiclet has no shadow, so only the
        // banner asks for one. AppKit derives the shape from the window's alpha,
        // which is the rounded glass fill, so the shadow follows the corners.
        panel.hasShadow = Self.usesBanner
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

        // Deliberately no `panel.appearance`. An earlier version pinned the
        // banner to .darkAqua, on the reading that the system's own banner looks
        // dark in Light mode too. That reading was the material doing its job:
        // glass takes its cast from whatever is behind it, so a banner captured
        // over dark content photographs dark in either appearance. Pinning it
        // froze that one sample in, which in Light mode over a light desktop
        // renders the dark glass variant: a smoked slab, the pre-26 look wearing
        // a new corner radius. Left alone, the view adapts, which is the entire
        // point of the material. Every colour below is therefore a semantic one
        // (labelColor and friends) so it resolves correctly in both appearances.

        func makeGlyphView() -> NSImageView {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            view.contentTintColor = .labelColor
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }

        if #available(macOS 26.0, *), Self.usesBanner {
            let level = BannerLevelView()
            level.translatesAutoresizingMaskIntoConstraints = false

            let leadingGlyph = makeGlyphView()
            let trailingGlyph = makeGlyphView()

            let title = NSTextField(labelWithString: "")
            title.font = Self.bannerTitleFont
            title.textColor = .labelColor
            // Left-aligned, matching the system banner. Centring it reads as a
            // notification's headline rather than as the name of the thing the
            // slider underneath belongs to.
            title.alignment = .left
            title.lineBreakMode = .byTruncatingTail
            title.maximumNumberOfLines = 1
            title.translatesAutoresizingMaskIntoConstraints = false
            // The banner's width is derived from this label's text, so the label
            // must not then argue with the result: a name past bannerMaxWidth
            // truncates inside the banner instead of stretching it wider.
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let content = NSView(frame: CGRect(origin: .zero, size: size))
            content.autoresizingMask = [.width, .height]
            content.addSubview(title)
            content.addSubview(leadingGlyph)
            content.addSubview(trailingGlyph)
            content.addSubview(level)

            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                               constant: Self.bannerLeadingInset),
                title.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                constant: -Self.bannerTrailingInset),
                title.topAnchor.constraint(equalTo: content.topAnchor,
                                           constant: Self.bannerTitleTopInset),

                // Both glyphs are centred on the track rather than on the
                // banner: the title occupies the upper half, so they belong to
                // the row they label, not to the box.
                leadingGlyph.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                                      constant: Self.bannerLeadingInset),
                leadingGlyph.centerYAnchor.constraint(equalTo: level.centerYAnchor),
                leadingGlyph.widthAnchor.constraint(equalToConstant: Self.bannerLeadingGlyphSize),
                leadingGlyph.heightAnchor.constraint(equalToConstant: Self.bannerLeadingGlyphSize),

                trailingGlyph.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                        constant: -Self.bannerTrailingInset),
                trailingGlyph.centerYAnchor.constraint(equalTo: level.centerYAnchor),
                trailingGlyph.widthAnchor.constraint(equalToConstant: Self.bannerTrailingGlyphSize),
                trailingGlyph.heightAnchor.constraint(equalToConstant: Self.bannerTrailingGlyphSize),

                level.leadingAnchor.constraint(equalTo: leadingGlyph.trailingAnchor,
                                               constant: Self.bannerGlyphToTrackGap),
                level.trailingAnchor.constraint(equalTo: trailingGlyph.leadingAnchor,
                                                constant: -Self.bannerGlyphToTrackGap),
                level.centerYAnchor.constraint(equalTo: content.bottomAnchor,
                                               constant: -Self.bannerRowCentreFromBottom),
                level.heightAnchor.constraint(equalToConstant: BannerLevelView.viewHeight),
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
            self.titleField = title
            self.leadingGlyphView = leadingGlyph
            self.trailingGlyphView = trailingGlyph
        } else {
            let glyph = makeGlyphView()
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
            self.glyphView = glyph
        }

        self.panel = panel
        return panel
    }

    private func symbol(named name: String, pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Places the panel: under MacQ's menu-bar icon when there is one on screen,
    /// and otherwise where that release's own indicator sits.
    ///
    /// NSScreen.frame is AppKit's bottom-left global space, not the top-left
    /// space CGDisplayBounds uses, so the display is looked up through NSScreen
    /// rather than converted by hand.
    private func position(_ panel: NSPanel, title: String, on displayID: CGDirectDisplayID) {
        let size = Self.usesBanner ? Self.bannerSize(for: title) : Self.legacySize

        if Self.usesBanner, let anchored = anchoredFrame(size: size) {
            notePlacement("under the menu-bar icon at x \(Int(anchored.midX.rounded()))")
            panel.setFrame(anchored, display: false)
            // The banner is re-measured against each title, so its width changes
            // between shows. A borderless window caches the shadow it derived
            // from the previous alpha shape, which would leave the old, wider
            // outline hanging off the new edge.
            panel.invalidateShadow()
            return
        }

        let screen = Self.screen(for: displayID) ?? NSScreen.screens.first
        guard let screen else { return }
        notePlacement("no menu-bar icon on screen, so top corner of display \(displayID)")

        let frame: CGRect
        if Self.usesBanner {
            // Top-trailing corner of the usable area. visibleFrame already has
            // the menu bar taken out on whichever display owns it, and equals
            // the full frame on a display that has none, so a single expression
            // covers both the built-in screen and the external panel.
            let area = screen.visibleFrame
            frame = CGRect(x: area.maxX - size.width - Self.bannerEdgeInset,
                           y: area.maxY - size.height - Self.bannerMenuBarGap,
                           width: size.width,
                           height: size.height)
        } else {
            frame = CGRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.minY + Self.legacyBottomInset,
                           width: size.width,
                           height: size.height)
        }
        panel.setFrame(frame, display: false)
        panel.invalidateShadow()
    }

    /// Records where the banner went, and only when that changes.
    ///
    /// "The indicator is in the wrong corner" has exactly two causes, and they
    /// need opposite fixes: MacQ could not find its menu-bar icon, or it found
    /// it somewhere unexpected. One line per keypress would drown the routing
    /// log, so this speaks only when the answer is new.
    private func notePlacement(_ text: String) {
        guard lastPlacement != text else { return }
        lastPlacement = text
        MediaKeyDiagnostics.shared.note("indicator: \(text)")
    }

    /// The banner hung under MacQ's menu-bar icon, or nil when there is no icon
    /// on screen to hang it from and the caller should place it itself.
    private func anchoredFrame(size: CGSize) -> CGRect? {
        guard let anchor = menuBarAnchor?(), anchor.width > 1 else { return nil }

        // Which screen the icon is on is decided by its midpoint rather than by
        // intersection: an item pushed off the end of a crowded menu bar can
        // still report a frame that clips the screen by a pixel, and hanging the
        // banner off a sliver of icon nobody can see is worse than falling back.
        let middle = CGPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) }) else {
            return nil
        }

        // Centred under the icon, then pulled back inside the screen, since an
        // icon near either end of the menu bar would otherwise hang the banner
        // half off the edge.
        let area = screen.visibleFrame
        let minX = area.minX + Self.bannerEdgeInset
        let maxX = max(minX, area.maxX - size.width - Self.bannerEdgeInset)
        let x = min(max(anchor.midX - size.width / 2, minX), maxX)

        // The icon's frame is the height of the menu bar on this Mac, but that
        // is not guaranteed across displays or releases, so the banner hangs
        // from whichever of the two edges is lower and stays clear of the bar
        // either way.
        let top = min(anchor.minY, area.maxY)
        return CGRect(x: x,
                      y: top - Self.bannerMenuBarGap - size.height,
                      width: size.width,
                      height: size.height)
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

/// macOS 26: a continuous capsule track with a round knob riding on it, the way
/// the system banner draws it.
///
/// The view is as tall as the knob rather than as tall as the track, so the knob
/// has room instead of being clipped at top and bottom; the track is drawn
/// centred inside that height.
private final class BannerLevelView: LevelView {

    static let viewHeight: CGFloat = 18
    static let trackHeight: CGFloat = 6
    static let knobDiameter: CGFloat = 18

    override func draw(_ dirtyRect: NSRect) {
        let trackRadius = Self.trackHeight / 2
        let track = NSRect(x: 0,
                           y: (bounds.height - Self.trackHeight) / 2,
                           width: bounds.width,
                           height: Self.trackHeight)

        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackRadius, yRadius: trackRadius).fill()

        // The knob's centre travels between the ends inset by its own radius, so
        // at 0 and at 1 it sits flush inside the track instead of hanging off
        // either end. The fill follows the knob rather than the raw fraction,
        // which is what keeps the two from drifting apart at the extremes.
        let radius = Self.knobDiameter / 2
        let centre = radius + max(0, bounds.width - Self.knobDiameter) * CGFloat(fraction)

        if centre > trackRadius {
            let filled = NSRect(x: 0, y: track.minY, width: centre, height: Self.trackHeight)
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: trackRadius, yRadius: trackRadius).fill()
        }

        let knob = NSRect(x: centre - radius,
                          y: (bounds.height - Self.knobDiameter) / 2,
                          width: Self.knobDiameter,
                          height: Self.knobDiameter)
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: knob).fill()
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
