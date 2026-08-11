import Foundation

nonisolated enum SystemCapability: String, CaseIterable, Sendable {
    case nativeScreenLock
    case displayIsolation
}

nonisolated enum SystemCapabilityAvailability: Equatable, Sendable {
    case unknown
    case available
    case unavailable(reason: String)
}

nonisolated final class SystemCapabilityRegistry: @unchecked Sendable {
    static let shared = SystemCapabilityRegistry()

    private let lock = NSLock()
    private var availability: [SystemCapability: SystemCapabilityAvailability] = [:]

    func status(for capability: SystemCapability) -> SystemCapabilityAvailability {
        lock.withLock {
            availability[capability] ?? .unknown
        }
    }

    func reportAvailable(_ capability: SystemCapability) {
        lock.withLock {
            availability[capability] = .available
        }
    }

    func reportUnavailable(_ capability: SystemCapability, reason: String) {
        lock.withLock {
            availability[capability] = .unavailable(reason: reason)
        }
    }
}
