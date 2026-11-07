import Foundation

nonisolated enum MouseLocalization {
    static func string(_ key: String, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier
        let localizedBundle = Bundle.main.path(forResource: locale.identifier, ofType: "lproj")
            ?? language.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
        let bundle = localizedBundle
            .flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

nonisolated enum MouseButtonSlot: String, CaseIterable, Codable, Identifiable, Sendable {
    case middle
    case back
    case forward
    case gesture

    var id: String { rawValue }

    func title(locale: Locale = .current) -> String {
        switch self {
        case .middle: MouseLocalization.string("mouse.slot.middle", locale: locale)
        case .back: MouseLocalization.string("mouse.slot.back", locale: locale)
        case .forward: MouseLocalization.string("mouse.slot.forward", locale: locale)
        case .gesture: MouseLocalization.string("mouse.slot.gesture", locale: locale)
        }
    }

    static let settingsOrder: [MouseButtonSlot] = [.middle, .gesture, .back, .forward]
}

nonisolated enum MouseButtonAction: String, CaseIterable, Identifiable, Sendable {
    case passThrough
    case browserBack
    case browserForward
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case commandTab
    case copy
    case paste
    case functionF13
    case functionF14
    case functionF15
    case customShortcut

    var id: String { rawValue }

    func title(locale: Locale = .current) -> String {
        switch self {
        case .passThrough: MouseLocalization.string("mouse.action.pass-through", locale: locale)
        case .browserBack: MouseLocalization.string("mouse.action.browser-back", locale: locale)
        case .browserForward: MouseLocalization.string("mouse.action.browser-forward", locale: locale)
        case .missionControl: MouseLocalization.string("mouse.action.mission-control", locale: locale)
        case .appExpose: MouseLocalization.string("mouse.action.app-expose", locale: locale)
        case .showDesktop: MouseLocalization.string("mouse.action.show-desktop", locale: locale)
        case .launchpad: MouseLocalization.string("mouse.action.launchpad", locale: locale)
        case .commandTab: MouseLocalization.string("mouse.action.command-tab", locale: locale)
        case .copy: MouseLocalization.string("mouse.action.copy", locale: locale)
        case .paste: MouseLocalization.string("mouse.action.paste", locale: locale)
        case .functionF13: MouseLocalization.string("mouse.action.function-f13", locale: locale)
        case .functionF14: MouseLocalization.string("mouse.action.function-f14", locale: locale)
        case .functionF15: MouseLocalization.string("mouse.action.function-f15", locale: locale)
        case .customShortcut: MouseLocalization.string("mouse.action.custom-shortcut", locale: locale)
        }
    }
}

nonisolated struct MouseShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
}

nonisolated struct MouseKeyboardShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: MouseShortcutModifiers
    let keyLabel: String

    var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyLabel
    }
}

nonisolated struct MouseButtonMapping: Equatable, Sendable {
    let action: MouseButtonAction
    let shortcut: MouseKeyboardShortcut?

    var isExecutable: Bool {
        action != .passThrough && (action != .customShortcut || shortcut != nil)
    }
}

struct LogitechMouseDevice: Identifiable, Equatable {
    let productID: Int
    let productName: String
    let transport: String
    let supportsDPI: Bool
    let dpiMin: Int
    let dpiMax: Int
    var currentDPI: Int?
    var batteryPercent: Int?

    var id: String {
        "\(productID)-\(productName)-\(transport)"
    }

    func displayName(locale: Locale) -> String {
        if productID == 0xB037 || productName.localizedCaseInsensitiveContains("Anywhere 3S") {
            return "MX Anywhere 3S"
        }
        return productName.isEmpty
            ? MouseLocalization.string("mouse.device.logitech", locale: locale)
            : productName
    }
}

enum MouseInputListenerPolicy {
    static func shouldRunEventTap(
        mouseControlEnabled: Bool,
        devicePresent: Bool
    ) -> Bool {
        mouseControlEnabled && devicePresent
    }

    static func shouldRunHIDPPGesture(
        mouseControlEnabled: Bool,
        devicePresent: Bool,
        mapping: MouseButtonMapping
    ) -> Bool {
        mouseControlEnabled && devicePresent && mapping.isExecutable
    }
}
