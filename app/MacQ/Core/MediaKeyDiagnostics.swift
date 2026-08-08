//
//  MediaKeyDiagnostics.swift
//  MacQ
//
//  A short, in-memory record of what the media-key pipeline saw and what it
//  decided.
//
//  This exists because "the brightness keys do nothing" is indistinguishable
//  from the outside from at least three different faults: the event never
//  reaches the tap, the event reaches the tap and is deliberately passed to
//  macOS, or the event is claimed and the DDC write is ignored by the panel.
//  Unified logging is not a usable channel here (`log show` returns nothing on
//  some machines), so the evidence has to surface in the app's own UI.
//
//  Recording is off unless the Keyboard settings tab is on screen, so the tap
//  callback pays nothing in normal use: the message is an @autoclosure and is
//  never built while `isRecording` is false.
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
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: at)
        }
    }

    /// Enough to hold a burst of auto-repeat plus the presses either side of it,
    /// short enough that the whole log is readable without scrolling far.
    private static let capacity = 80

    @Published private(set) var entries: [Entry] = []

    /// Set by the Keyboard settings tab while it is visible. Nothing is recorded
    /// otherwise.
    @Published var isRecording = false

    private var nextID = 0

    private init() {}

    func record(_ text: @autoclosure () -> String) {
        guard isRecording else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        nextID &+= 1
        entries.append(Entry(id: nextID, at: Date(), text: text()))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func clear() {
        dispatchPrecondition(condition: .onQueue(.main))
        entries.removeAll()
    }

    /// The whole log as plain text, for pasting into a bug report.
    var transcript: String {
        entries.map { "\($0.timestamp)  \($0.text)" }.joined(separator: "\n")
    }
}
