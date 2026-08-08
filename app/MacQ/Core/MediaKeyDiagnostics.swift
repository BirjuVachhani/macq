//
//  MediaKeyDiagnostics.swift
//  MacQ
//
//  A short, in-memory record of what the media-key pipeline saw and what it
//  decided.
//
//  This exists because "the brightness keys do nothing" is indistinguishable
//  from the outside from at least four different faults: the tap was never
//  installed, the event never reaches the tap, the event reaches the tap and is
//  deliberately passed to macOS, or the event is claimed and the DDC write is
//  ignored by the panel. Unified logging is not a usable channel here (`log
//  show` returns nothing on some machines), so the evidence has to surface
//  somewhere the app itself controls.
//
//  Per-key recording is off unless the Keyboard settings tab is on screen or the
//  file sink is enabled, so the tap callback pays nothing in normal use: the
//  message is an @autoclosure and is never built while `isRecording` is false.
//  Lifecycle lines go in either way, because those are what explain an empty log.
//
//  The optional file sink is enabled with:
//
//      defaults write dev.birjuvachhani.macq debugKeyLog -bool YES
//
//  It exists because the settings window is a poor instrument for a feature
//  whose routing depends on where the pointer is: opening the window to read the
//  log tends to put the pointer on the window, which is itself an input to the
//  decision being observed. Even with the sink on, the file holds only the five
//  media keys, the routing decision for each, and the tap's own lifecycle.
//
//  Main thread only, matching the rest of the media-key pipeline.
//

import Combine
import Foundation

final class MediaKeyDiagnostics: ObservableObject {

    static let shared = MediaKeyDiagnostics()

    struct Entry: Identifiable {
        let id: Int
        let at: Date
        let text: String

        var timestamp: String {
            Entry.formatter.string(from: at)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    /// Enough to hold a burst of auto-repeat plus the presses either side of it,
    /// short enough that the whole log is readable without scrolling far.
    private static let capacity = 80

    private static let fileLogKey = "debugKeyLog"

    static let logURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacQ/mediakeys.log")

    @Published private(set) var entries: [Entry] = []

    /// True while anything is listening. Read on every systemDefined event from
    /// inside the tap callback, so it stays a plain stored property.
    private(set) var isRecording = false

    /// Whether the file sink was asked for. Read once at launch: a debug switch
    /// that changes underneath a running tap is harder to reason about than one
    /// that needs a relaunch.
    let isFileLogging: Bool

    private var panelVisible = false
    private var nextID = 0
    private var reportedSubtypes: Set<Int> = []

    /// The file is written off the main thread. `record` runs inside the event
    /// tap callback, and a callback that blocks long enough gets the tap
    /// disabled by the system.
    private let fileQueue = DispatchQueue(label: "dev.birjuvachhani.MacQ.diagnostics.file",
                                          qos: .utility)
    private var handle: FileHandle?

    private init() {
        isFileLogging = UserDefaults.standard.bool(forKey: Self.fileLogKey)
        isRecording = isFileLogging
        if isFileLogging { openLogFile() }
    }

    // MARK: - Recording

    /// Records one line about a keypress. Gated, because the systemDefined event
    /// stream also carries aux mouse buttons and would otherwise bury every
    /// interesting line under mouse clicks.
    func record(_ text: @autoclosure () -> String) {
        guard isRecording else { return }
        append(text())
    }

    /// Records a lifecycle line: tap armed, tap refused, permission missing.
    /// Always kept, so the log explains an absence of keypress lines rather than
    /// just being empty.
    func note(_ text: String) {
        append(text)
    }

    /// Records the first event of each systemDefined subtype and then stays quiet
    /// about it.
    ///
    /// The subtype MacQ cares about is 8, but the same stream carries aux mouse
    /// buttons (subtype 7), which arrive on every click and would push the media
    /// keys out of an 80 line ring within seconds. One line per subtype still
    /// answers the only question those events are useful for: is the tap alive
    /// and receiving anything at all.
    func recordFirst(subtype: Int, _ text: @autoclosure () -> String) {
        guard isRecording else { return }
        guard reportedSubtypes.insert(subtype).inserted else { return }
        append(text())
    }

    private func append(_ text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let at = Date()
        nextID &+= 1
        entries.append(Entry(id: nextID, at: at, text: text))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        guard isFileLogging else { return }
        fileQueue.async { [weak self] in self?.write(text, at: at) }
    }

    func clear() {
        dispatchPrecondition(condition: .onQueue(.main))
        entries.removeAll()
        // So that "Clear, then click something" proves the tap is still live,
        // rather than showing nothing because the subtype was already reported.
        reportedSubtypes.removeAll()
    }

    /// Called by the Keyboard settings tab as it appears and disappears. The file
    /// sink, if on, keeps recording either way.
    func setPanelVisible(_ visible: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        panelVisible = visible
        isRecording = panelVisible || isFileLogging
    }

    /// The whole log as plain text, for pasting into a bug report.
    var transcript: String {
        entries.map { "\($0.timestamp)  \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - File sink

    /// Truncated at every launch rather than appended to forever. This is a
    /// debugging aid for the session in front of you, and an unbounded log that
    /// nothing rotates is its own bug.
    private func openLogFile() {
        let url = Self.logURL
        fileQueue.async { [weak self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
            self?.handle = try? FileHandle(forWritingTo: url)
        }
    }

    private func write(_ text: String, at date: Date) {
        dispatchPrecondition(condition: .onQueue(fileQueue))
        guard let handle,
              let data = "\(Self.fileFormatter.string(from: date))  \(text)\n".data(using: .utf8)
        else { return }
        try? handle.write(contentsOf: data)
    }

    /// Full date, unlike the UI's: a file outlives the session that wrote it.
    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
