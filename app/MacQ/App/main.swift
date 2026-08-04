//
//  main.swift
//  MacQ
//
//  AppKit entry point. We manage the status item and popover directly (instead
//  of SwiftUI's MenuBarExtra scene, which proved fragile: its scene backing
//  received a teardown action and quit the app at launch). SwiftUI views are
//  still used, hosted via NSHostingController.
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
