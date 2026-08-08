import ApplicationServices
import Foundation
import OSLog

final class MouseButtonEventTap {
    private weak var settings: MonitorSettings?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let actionQueue = DispatchQueue(label: "com.fanshu.monitor.mouse-actions", qos: .userInitiated)

    init(settings: MonitorSettings) {
        self.settings = settings
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else {
            AppLogger.mouse.info("Mouse button tap waiting for Accessibility permission")
            return false
        }

        let mask = (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.callback,
            userInfo: pointer
        ) else {
            AppLogger.mouse.error("Mouse button tap creation failed")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.mouse.info("Mouse button tap started")
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        AppLogger.mouse.info("Mouse button tap stopped")
    }

    func refresh() {
        guard settings?.mouseControlEnabled == true else {
            stop()
            return
        }
        guard AXIsProcessTrusted() else {
            stop()
            AppLogger.mouse.info("Mouse button tap stopped because Accessibility permission was revoked")
            return
        }
        start()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard settings?.mouseControlEnabled == true else {
            return Unmanaged.passUnretained(event)
        }

        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        let slot: MouseButtonSlot?
        switch buttonNumber {
        case 2: slot = .middle
        case 3: slot = .back
        case 4: slot = .forward
        default: slot = nil
        }

        guard let slot else {
            return Unmanaged.passUnretained(event)
        }

        let mapping = settings?.mouseMapping(for: slot)
            ?? MouseButtonMapping(action: .passThrough, shortcut: nil)
        guard mapping.isExecutable else {
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown {
            AppLogger.mouse.debug("Mouse button \(slot.rawValue, privacy: .public) mapped to \(mapping.action.rawValue, privacy: .public)")
            actionQueue.async {
                MouseActionExecutor.execute(mapping)
            }
        }
        return nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let tap = Unmanaged<MouseButtonEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                if let eventTap = tap.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                    AppLogger.mouse.info("Mouse button tap re-enabled by callback")
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let tap = Unmanaged<MouseButtonEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }
}
