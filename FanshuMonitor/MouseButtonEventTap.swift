import ApplicationServices
import Foundation
import OSLog

final class MouseButtonEventTap {
    private weak var settings: MonitorSettings?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning = false
    private let permissionProvider: () -> Bool
    private let startOverride: (() -> Bool)?
    private let stopOverride: (() -> Void)?
    private let executeAction: (MouseButtonMapping) -> Void
    private var consumedButtons: Set<Int64> = []

    init(settings: MonitorSettings, permissionProvider: @escaping () -> Bool = { AXIsProcessTrusted() },
         startOverride: (() -> Bool)? = nil, stopOverride: (() -> Void)? = nil,
         executeAction: @escaping (MouseButtonMapping) -> Void = { MouseActionExecutor.execute($0) }) {
        self.settings = settings
        self.permissionProvider = permissionProvider
        self.startOverride = startOverride
        self.stopOverride = stopOverride
        self.executeAction = executeAction
    }

    deinit {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    @discardableResult
    func start() -> Bool {
        guard permissionProvider() else {
            stop()
            AppLogger.mouse.info("Mouse button tap waiting for Accessibility permission")
            return false
        }
        if isRunning {
            if startOverride != nil { return true }
            if let eventTap, CFMachPortIsValid(eventTap),
               runLoopSource.map(CFRunLoopSourceIsValid) == true {
                if !CGEvent.tapIsEnabled(tap: eventTap) {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                if CGEvent.tapIsEnabled(tap: eventTap) { return true }
            }
            stop()
        }
        if let startOverride {
            isRunning = startOverride()
            return isRunning
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

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            AppLogger.mouse.error("Mouse button tap run-loop source creation failed")
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            return false
        }
        isRunning = true
        AppLogger.mouse.info("Mouse button tap started")
        return true
    }

    func stop() {
        consumedButtons.removeAll()
        if isRunning { stopOverride?() }
        isRunning = false
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
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
        guard permissionProvider() else {
            stop()
            AppLogger.mouse.info("Mouse button tap stopped because Accessibility permission was revoked")
            return
        }
        start()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .otherMouseDown || type == .otherMouseUp,
              event.getIntegerValueField(.eventSourceUserData) != MouseActionExecutor.generatedEventMarker else {
            return Unmanaged.passUnretained(event)
        }
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        if type == .otherMouseUp {
            return consumedButtons.remove(buttonNumber) != nil ? nil : Unmanaged.passUnretained(event)
        }
        if consumedButtons.contains(buttonNumber) { return nil }
        guard settings?.mouseControlEnabled == true else {
            return Unmanaged.passUnretained(event)
        }

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

        consumedButtons.insert(buttonNumber)
        executeAction(mapping)
        return nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let tap = Unmanaged<MouseButtonEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                tap.consumedButtons.removeAll()
                if let eventTap = tap.eventTap {
                    // Leave the input path open after a timeout. Activation or
                    // an explicit settings refresh can safely recreate it.
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                    AppLogger.mouse.error("Mouse button tap disabled by system; waiting for activation to retry")
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
