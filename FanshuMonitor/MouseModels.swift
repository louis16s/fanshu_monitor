import Foundation

nonisolated enum MouseButtonSlot: String, CaseIterable, Codable, Identifiable, Sendable {
    case middle
    case back
    case forward
    case gesture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .middle: "中键"
        case .back: "后退键"
        case .forward: "前进键"
        case .gesture: "手势键"
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

    var title: String {
        switch self {
        case .passThrough: "透传"
        case .browserBack: "浏览器后退"
        case .browserForward: "浏览器前进"
        case .missionControl: "调度中心"
        case .appExpose: "应用窗口"
        case .showDesktop: "显示桌面"
        case .launchpad: "启动台"
        case .commandTab: "切换应用"
        case .copy: "复制"
        case .paste: "粘贴"
        case .functionF13: "功能键 F13"
        case .functionF14: "功能键 F14"
        case .functionF15: "功能键 F15"
        case .customShortcut: "自定义快捷键"
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

    var displayName: String {
        if productID == 0xB037 || productName.localizedCaseInsensitiveContains("Anywhere 3S") {
            return "MX Anywhere 3S"
        }
        return productName.isEmpty ? "Logitech 鼠标" : productName
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
