import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem
import OSLog

@MainActor
final class BrightnessKeyEventTap {
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
    private weak var settings: MonitorSettings?
    private weak var displayController: DisplayControlController?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastAccessibilityWaitingLogDate: Date?

    init(settings: MonitorSettings, displayController: DisplayControlController) {
        self.settings = settings
        self.displayController = displayController
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    func start() {
        guard eventTap == nil else { return }
        guard settings?.brightnessKeyInterceptionEnabled == true else { return }
        guard Self.canInterceptBrightnessKeys(
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: CGPreflightListenEventAccess()
        ) else {
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << Self.systemDefinedEventType.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.eventCallback,
            userInfo: userInfo
        ) else {
            AppLogger.ui.error("Unable to create brightness key event tap; check Accessibility/Input Monitoring permissions and sandbox state")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.ui.notice("Brightness key event tap started")
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
    }

    func refreshPermissionState() {
        guard settings?.brightnessKeyInterceptionEnabled == true else {
            stop()
            return
        }

        let hasPermission = Self.canInterceptBrightnessKeys(
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: CGPreflightListenEventAccess()
        )
        guard hasPermission else {
            stop()
            logWaitingForAccessibility()
            return
        }
        start()
    }

    private func handle(event: CGEvent, type: CGEventType) -> Bool {
        guard settings?.brightnessKeyInterceptionEnabled == true else {
            return false
        }
        guard let mediaKey = MediaBrightnessKey(event: event, type: type), mediaKey.isKeyDown else {
            return false
        }
        guard let displayController else {
            AppLogger.ui.debug("Brightness key pass-through: display controller unavailable")
            return false
        }
        guard let target = displayController.brightnessDisplayUnderMouse() else {
            return false
        }

        let configuredStep = min(20, max(1, settings?.brightnessKeyStepPercent ?? 6.25))
        let step = mediaKey.isFineIncrement ? max(0.5, configuredStep / 4.0) : configuredStep
        let current = displayController.value(for: .brightness, displayID: target.id)
        let next = min(100, max(0, current + (mediaKey.isUp ? step : -step)))
        AppLogger.ui.debug("Brightness key handled for display \(target.id), value \(next, privacy: .public)")
        displayController.setKeyboardBrightnessValue(next, displayID: target.id)
        if settings?.displayNativeOSDEnabled == true {
            NativeOSDService.showBrightness(displayID: target.id, value: next)
        }
        return true
    }

    nonisolated static func canInterceptBrightnessKeys(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool
    ) -> Bool {
        accessibilityGranted && inputMonitoringGranted
    }

    private func logWaitingForAccessibility() {
        let now = Date()
        if let lastAccessibilityWaitingLogDate,
           now.timeIntervalSince(lastAccessibilityWaitingLogDate) < 30 {
            return
        }
        lastAccessibilityWaitingLogDate = now
        AppLogger.ui.notice("Brightness key interception is waiting for keyboard capture permissions")
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let tap = Unmanaged<BrightnessKeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = tap.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == systemDefinedEventType || type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let handled = tap.handle(event: event, type: type)
        return handled ? nil : Unmanaged.passUnretained(event)
    }
}

private struct MediaBrightnessKey {
    let isUp: Bool
    let isKeyDown: Bool
    let isFineIncrement: Bool

    init?(event: CGEvent, type: CGEventType) {
        if type == .keyDown {
            let keyCode = Int32(event.getIntegerValueField(.keyboardEventKeycode))
            switch keyCode {
            case 120, 144:
                isUp = true
            case 122, 145:
                isUp = false
            case 113:
                isUp = true
            case 107:
                isUp = false
            default:
                return nil
            }
            isKeyDown = true
            let flags = event.flags
            isFineIncrement = flags.contains(.maskAlternate) && flags.contains(.maskShift)
            return
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS) else {
            return nil
        }

        let eventData = Int64(nsEvent.data1)
        let keyCode = Int32((eventData & 0xFFFF0000) >> 16)
        let keyFlags = Int32(eventData & 0x0000FFFF)
        let keyState = (keyFlags & 0xFF00) >> 8

        switch keyCode {
        case NX_KEYTYPE_BRIGHTNESS_UP:
            isUp = true
        case NX_KEYTYPE_BRIGHTNESS_DOWN:
            isUp = false
        default:
            return nil
        }

        isKeyDown = keyState == 0x0A
        let flags = event.flags
        isFineIncrement = flags.contains(.maskAlternate) && flags.contains(.maskShift)
    }
}
