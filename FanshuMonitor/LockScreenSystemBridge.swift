import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt
import OSLog

enum DirectLockSchedule {
    static func remainingDelay(idleSeconds: TimeInterval, threshold: TimeInterval) -> TimeInterval {
        max(1, threshold - idleSeconds + 0.25)
    }
}

enum SystemIdleTime {
    private static let anyInputEvent = CGEventType(rawValue: UInt32.max)!

    static func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
    }
}

enum SystemSessionState {
    private static let screenLockedKey = "CGSSessionScreenIsLocked"

    static func isScreenLocked() -> Bool {
        screenIsLocked(in: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    static func screenIsLocked(in dictionary: [String: Any]?) -> Bool {
        guard let value = dictionary?[screenLockedKey] else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool ?? false
    }
}

enum DirectScreenLocker {
    private typealias NativeLockFunction = @convention(c) () -> Void
    private static let loginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    private static let nativeLockSymbol = "SACLockScreenImmediate"
    private static let qKeyCode: CGKeyCode = 12
    private static let modifierFlags: CGEventFlags = [.maskControl, .maskCommand]

    static func requestNativeLock() -> Bool {
        guard let handle = dlopen(loginFrameworkPath, RTLD_NOW | RTLD_LOCAL) else {
            AppLogger.lockScreen.error("Unable to load the system login framework")
            return false
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, nativeLockSymbol) else {
            AppLogger.lockScreen.error("System lock function is unavailable")
            return false
        }

        let lockFunction = unsafeBitCast(symbol, to: NativeLockFunction.self)
        lockFunction()
        AppLogger.lockScreen.notice("Requested direct lock through the system login service")
        return true
    }

    static func requestKeyboardLock() -> Bool {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: qKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: qKeyCode, keyDown: false) else {
            AppLogger.lockScreen.error("Keyboard lock fallback is unavailable")
            return false
        }

        keyDown.flags = modifierFlags
        keyUp.flags = modifierFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        AppLogger.lockScreen.notice("Requested direct lock through the keyboard fallback")
        return true
    }
}

/// Keeps macOS from turning the display off before a direct-lock policy reaches its threshold.
/// Explicit sleep, manual lock, and lid-close behavior remain available.
nonisolated final class IdleDisplaySleepAssertion {
    private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

    var isActive: Bool {
        assertionID != kIOPMNullAssertionID
    }

    @discardableResult
    func acquire() -> Bool {
        guard !isActive else { return true }
        var newAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "番薯Monitor 正在等待直接锁定" as CFString,
            &newAssertionID
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = newAssertionID
        return true
    }

    func release() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    }

    deinit {
        release()
    }
}

enum ScreenSaverLockPreferences {
    private static let domain = "com.apple.screensaver" as CFString

    static func read() -> ScreenSaverLockBaseline {
        ScreenSaverLockBaseline(
            idleTime: integer(for: "idleTime", host: true),
            askForPassword: bool(for: "askForPassword", host: false),
            askForPasswordDelay: integer(for: "askForPasswordDelay", host: false)
        )
    }

    @discardableResult
    static func apply(
        idleSeconds: Int,
        requirePassword: Bool,
        passwordDelaySeconds: Int = 0
    ) -> Bool {
        var succeeded = set(idleSeconds, for: "idleTime", host: true)
        if requirePassword {
            succeeded = set(true, for: "askForPassword", host: false) && succeeded
            succeeded = set(passwordDelaySeconds, for: "askForPasswordDelay", host: false) && succeeded
        } else {
            succeeded = set(false, for: "askForPassword", host: false) && succeeded
        }
        let current = read()
        return succeeded
            && current.idleTime == idleSeconds
            && current.askForPassword == requirePassword
            && (!requirePassword || current.askForPasswordDelay == passwordDelaySeconds)
    }

    @discardableResult
    static func disableIdleScreenSaver() -> Bool {
        set(0, for: "idleTime", host: true) && isIdleScreenSaverDisabled
    }

    static var isIdleScreenSaverDisabled: Bool {
        integer(for: "idleTime", host: true) == 0
    }

    @discardableResult
    static func restore(_ baseline: ScreenSaverLockBaseline) -> Bool {
        var succeeded = set(baseline.idleTime, for: "idleTime", host: true)
        succeeded = set(baseline.askForPassword, for: "askForPassword", host: false) && succeeded
        succeeded = set(baseline.askForPasswordDelay, for: "askForPasswordDelay", host: false) && succeeded
        return succeeded && read() == baseline
    }

    private static func integer(for key: String, host: Bool) -> Int? {
        value(for: key, host: host).flatMap { value in
            if let number = value as? NSNumber { return number.intValue }
            return value as? Int
        }
    }

    private static func bool(for key: String, host: Bool) -> Bool? {
        value(for: key, host: host).flatMap { value in
            if let number = value as? NSNumber { return number.boolValue }
            return value as? Bool
        }
    }

    private static func value(for key: String, host: Bool) -> Any? {
        CFPreferencesCopyValue(
            key as CFString,
            domain,
            kCFPreferencesCurrentUser,
            host ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        )
    }

    private static func set(_ value: Any?, for key: String, host: Bool) -> Bool {
        let hostScope = host ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        CFPreferencesSetValue(
            key as CFString,
            value as CFPropertyList?,
            domain,
            kCFPreferencesCurrentUser,
            hostScope
        )
        return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, hostScope)
    }
}
