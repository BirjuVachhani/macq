//
//  AliasStore.swift
//  MacQ
//
//  Persists user-chosen names for input sources, per physical monitor.
//

import Foundation

final class AliasStore {
    private let defaults: UserDefaults
    private let rootKey = "inputSourceAliases"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Nested map: displayKey -> ("0xNN" -> alias).
    private var all: [String: [String: String]] {
        get { defaults.dictionary(forKey: rootKey) as? [String: [String: String]] ?? [:] }
        set { defaults.set(newValue, forKey: rootKey) }
    }

    private func field(_ value: UInt8) -> String { String(format: "0x%02X", value) }

    func alias(displayKey: String, writeValue: UInt8) -> String? {
        let a = all[displayKey]?[field(writeValue)]
        return (a?.isEmpty == false) ? a : nil
    }

    func setAlias(_ alias: String?, displayKey: String, writeValue: UInt8) {
        var map = all
        var perDisplay = map[displayKey] ?? [:]
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            perDisplay[field(writeValue)] = trimmed
        } else {
            perDisplay.removeValue(forKey: field(writeValue))
        }
        map[displayKey] = perDisplay
        all = map
    }

    /// Resolves the label to show: user alias if set, otherwise the default.
    func displayLabel(for source: InputSource, displayKey: String) -> String {
        alias(displayKey: displayKey, writeValue: source.writeValue) ?? source.defaultLabel
    }
}
