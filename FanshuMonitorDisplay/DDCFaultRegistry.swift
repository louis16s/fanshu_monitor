import CoreGraphics
import Foundation

nonisolated final class DDCFaultRegistry {
    static let readFaultDisableThreshold = 5
    static let readFaultLongerDelayThreshold = 3
    static let writeFaultDisableThreshold = 10
    static let disableCooldown: TimeInterval = 5

    private struct State {
        var readFaults = 0
        var writeFaults = 0
        var disabledUntil: Date?
    }

    private var states: [ControlKey: State] = [:]
    private let lock = NSLock()

    func recordReadFailure(_ key: ControlKey) {
        lock.lock()
        defer { lock.unlock() }
        var state = states[key] ?? State()
        state.readFaults += 1
        if state.readFaults >= Self.readFaultDisableThreshold {
            state.disabledUntil = Date().addingTimeInterval(Self.disableCooldown)
        }
        states[key] = state
    }

    func recordReadSuccess(_ key: ControlKey) {
        lock.lock()
        defer { lock.unlock() }
        var state = states[key] ?? State()
        state.readFaults = 0
        state.disabledUntil = nil
        states[key] = state
    }

    func recordWriteFailure(_ key: ControlKey) {
        lock.lock()
        defer { lock.unlock() }
        var state = states[key] ?? State()
        state.writeFaults += 1
        if state.writeFaults >= Self.writeFaultDisableThreshold {
            state.disabledUntil = Date().addingTimeInterval(Self.disableCooldown)
        }
        states[key] = state
    }

    func recordWriteSuccess(_ key: ControlKey) {
        lock.lock()
        defer { lock.unlock() }
        var state = states[key] ?? State()
        state.writeFaults = 0
        state.disabledUntil = nil
        states[key] = state
    }

    func isDisabled(_ key: ControlKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let disabledUntil = states[key]?.disabledUntil else {
            return false
        }
        return Date() < disabledUntil
    }

    func shouldUseLongerDelay(_ key: ControlKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (states[key]?.readFaults ?? 0) >= Self.readFaultLongerDelayThreshold
    }

    func reset(displayID: CGDirectDisplayID) {
        lock.lock()
        defer { lock.unlock() }
        for key in states.keys where key.displayID == displayID {
            states.removeValue(forKey: key)
        }
    }
}
