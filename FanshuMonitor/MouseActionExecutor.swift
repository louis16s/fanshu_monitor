import AppKit
import ApplicationServices
import OSLog

nonisolated final class MouseActionExecutor: @unchecked Sendable {
    static let generatedEventMarker: Int64 = 0x46414E5348554D
    static let maximumPendingActions = 8
    private static let shared = MouseActionExecutor()
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pendingActions = 0
    private let postEvent: @Sendable (CGEvent) -> Void
    private let openLauncher: @Sendable () -> Void

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.fanshu.monitor.mouse-actions", qos: .userInitiated),
        postEvent: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
        openLauncher: @escaping @Sendable () -> Void = { MouseActionExecutor.openSystemLauncher() }
    ) {
        self.queue = queue
        self.postEvent = postEvent
        self.openLauncher = openLauncher
    }

    static func execute(_ mapping: MouseButtonMapping) {
        _ = shared.enqueue(mapping)
    }

    @discardableResult
    func enqueue(_ mapping: MouseButtonMapping) -> Bool {
        guard mapping.isExecutable else { return false }
        let accepted = lock.withLock {
            guard pendingActions < Self.maximumPendingActions else { return false }
            pendingActions += 1
            return true
        }
        guard accepted else { return false }
        queue.async { [self] in
            defer { lock.withLock { pendingActions -= 1 } }
            perform(mapping)
        }
        return true
    }

    private func perform(_ mapping: MouseButtonMapping) {
        switch mapping.action {
        case .passThrough:
            return
        case .browserBack:
            key(.leftArrow, modifiers: .maskCommand)
        case .browserForward:
            key(.rightArrow, modifiers: .maskCommand)
        case .missionControl:
            key(.upArrow, modifiers: .maskControl)
        case .appExpose:
            key(.downArrow, modifiers: .maskControl)
        case .showDesktop:
            key(.f11, modifiers: [])
        case .launchpad:
            openLauncher()
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

    private func eventFlags(for modifiers: MouseShortcutModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    private static func openSystemLauncher() {
        let candidates = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            AppLogger.mouse.error("System app launcher is unavailable")
            return
        }
        Task { @MainActor in
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    AppLogger.mouse.error("Unable to open system app launcher: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func key(_ keyCode: CGKeyCode, modifiers: CGEventFlags) {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        source.localEventsSuppressionInterval = 0
        down.flags = modifiers
        // Release synthetic modifiers with the key so Command-Tab cannot leave
        // the application switcher waiting for a physical Command release.
        up.flags = []
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: Self.generatedEventMarker)
            postEvent(event)
        }
    }
}

private extension CGKeyCode {
    nonisolated static let tab: CGKeyCode = 48
    nonisolated static let keyC: CGKeyCode = 8
    nonisolated static let keyV: CGKeyCode = 9
    nonisolated static let leftArrow: CGKeyCode = 123
    nonisolated static let rightArrow: CGKeyCode = 124
    nonisolated static let downArrow: CGKeyCode = 125
    nonisolated static let upArrow: CGKeyCode = 126
    nonisolated static let f11: CGKeyCode = 103
    nonisolated static let f13: CGKeyCode = 105
    nonisolated static let f14: CGKeyCode = 107
    nonisolated static let f15: CGKeyCode = 113
}
