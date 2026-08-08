import AppKit
import ApplicationServices

enum MouseActionExecutor {
    @_silgen_name("CoreDockSendNotification")
    private static func coreDockSendNotification(_ name: CFString, _ unknown: Int32) -> Int32

    static func execute(_ mapping: MouseButtonMapping) {
        switch mapping.action {
        case .passThrough:
            return
        case .browserBack:
            key(.leftArrow, modifiers: .maskCommand)
        case .browserForward:
            key(.rightArrow, modifiers: .maskCommand)
        case .missionControl:
            if !dockNotification("com.apple.expose.awake") {
                key(.upArrow, modifiers: .maskControl)
            }
        case .appExpose:
            if !dockNotification("com.apple.expose.front.awake") {
                key(.downArrow, modifiers: .maskControl)
            }
        case .showDesktop:
            if !dockNotification("com.apple.showdesktop.awake") {
                key(.f11, modifiers: [])
            }
        case .launchpad:
            if !dockNotification("com.apple.launchpad.toggle") {
                key(.f4, modifiers: [])
            }
        case .commandTab:
            key(.tab, modifiers: .maskCommand)
        case .copy:
            key(.keyC, modifiers: .maskCommand)
        case .paste:
            key(.keyV, modifiers: .maskCommand)
        case .functionF13:
            key(.f13, modifiers: [])
        case .functionF14:
            key(.f14, modifiers: [])
        case .functionF15:
            key(.f15, modifiers: [])
        case .customShortcut:
            guard let shortcut = mapping.shortcut else { return }
            key(
                CGKeyCode(shortcut.keyCode),
                modifiers: eventFlags(for: shortcut.modifiers)
            )
        }
    }

    private static func eventFlags(for modifiers: MouseShortcutModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    private static func dockNotification(_ name: String) -> Bool {
        coreDockSendNotification(name as CFString, 0) == 0
    }

    private static func key(_ keyCode: CGKeyCode, modifiers: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private extension CGKeyCode {
    static let tab: CGKeyCode = 48
    static let space: CGKeyCode = 49
    static let keyC: CGKeyCode = 8
    static let keyV: CGKeyCode = 9
    static let leftArrow: CGKeyCode = 123
    static let rightArrow: CGKeyCode = 124
    static let downArrow: CGKeyCode = 125
    static let upArrow: CGKeyCode = 126
    static let f4: CGKeyCode = 118
    static let f11: CGKeyCode = 103
    static let f13: CGKeyCode = 105
    static let f14: CGKeyCode = 107
    static let f15: CGKeyCode = 113
}
