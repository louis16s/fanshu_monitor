import Foundation
import IOKit
import OSLog

nonisolated enum DisplayHardwareTopologyEvent: Sendable, Equatable {
    case externalServiceAdded
    case externalServiceRemoved
    case displayServiceChanged
}

nonisolated enum DisplayHardwareServiceLocation: Sendable, Equatable {
    case embedded
    case external
    case unknown

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "embedded":
            self = .embedded
        case "external":
            self = .external
        default:
            self = .unknown
        }
    }
}

/// Converts low-level IOKit events into stable topology notifications. The
/// controller never needs to reason about registry timing or service location.
@MainActor
final class DisplayHardwareTopologyMonitor {
    private let topologyChanged: @MainActor @Sendable (DisplayHardwareTopologyEvent) -> Void
    private let lastExternalServiceRemoved: @MainActor @Sendable () -> Void
    private var bridge: DisplayHardwareTopologyBridge?
    private var verificationTask: Task<Void, Never>?
    private var isSystemSleeping = false

    init(
        topologyChanged: @escaping @MainActor @Sendable (DisplayHardwareTopologyEvent) -> Void,
        lastExternalServiceRemoved: @escaping @MainActor @Sendable () -> Void
    ) {
        self.topologyChanged = topologyChanged
        self.lastExternalServiceRemoved = lastExternalServiceRemoved
    }

    @discardableResult
    func start() -> Bool {
        guard bridge == nil else { return true }
        let bridge = DisplayHardwareTopologyBridge { [weak self] event in
            self?.receive(event)
        }
        guard bridge.start() else { return false }
        self.bridge = bridge
        return true
    }

    func stop() {
        verificationTask?.cancel()
        verificationTask = nil
        bridge?.stop()
        bridge = nil
    }

    func externalServiceCount() -> Int? {
        bridge?.externalServiceCount()
    }

    func setSystemSleeping(_ sleeping: Bool) {
        isSystemSleeping = sleeping
        if sleeping {
            verificationTask?.cancel()
            verificationTask = nil
        }
    }

    private func receive(_ event: DisplayHardwareTopologyEvent) {
        topologyChanged(event)
        switch event {
        case .externalServiceAdded:
            verificationTask?.cancel()
            verificationTask = nil
        case .externalServiceRemoved:
            AppLogger.ui.notice("External display hardware service terminated; verifying final disconnect")
            guard DisplayWakeMaintenancePolicy.shouldVerifyExternalDisconnect(
                isSystemSleeping: isSystemSleeping
            ) else {
                return
            }
            scheduleFinalDisconnectVerification(
                delay: DisplayHardwareDisconnectRecoveryPolicy.confirmedRemovalDelay
            )
        case .displayServiceChanged:
            // A terminated service can lose its Location property before the
            // callback is delivered, so unknown changes get a later recount.
            guard DisplayWakeMaintenancePolicy.shouldVerifyExternalDisconnect(
                isSystemSleeping: isSystemSleeping
            ) else {
                return
            }
            scheduleFinalDisconnectVerification(
                delay: DisplayHardwareDisconnectRecoveryPolicy.unknownChangeDelay
            )
        }
    }

    private func scheduleFinalDisconnectVerification(delay: TimeInterval) {
        verificationTask?.cancel()
        verificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.verificationTask = nil
            guard self.bridge?.externalServiceCount() == 0 else { return }
            self.lastExternalServiceRemoved()
        }
    }

    deinit {
        verificationTask?.cancel()
        bridge?.stop()
    }
}

/// Watches the Apple Silicon display service tree independently from
/// WindowServer. CoreGraphics can retain a stale external display after a
/// physical disconnect, while the DCP service termination still arrives.
nonisolated final class DisplayHardwareTopologyBridge: @unchecked Sendable {
    private enum ServiceEvent: String {
        case matched
        case terminated

        var notificationName: String {
            switch self {
            case .matched: kIOFirstMatchNotification
            case .terminated: kIOTerminatedNotification
            }
        }
    }

    private static let serviceClass = "DCPAVServiceProxy"

    private let handler: @MainActor @Sendable (DisplayHardwareTopologyEvent) -> Void
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t: ServiceEvent] = [:]
    private var knownLocations: [UInt64: DisplayHardwareServiceLocation] = [:]

    init(handler: @escaping @MainActor @Sendable (DisplayHardwareTopologyEvent) -> Void) {
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        guard notificationPort == nil else { return true }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            AppLogger.ui.error("Unable to create display hardware notification port")
            return false
        }

        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        for event in [ServiceEvent.matched, .terminated] {
            guard let matching = IOServiceMatching(Self.serviceClass) else { continue }
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port,
                event.notificationName,
                matching,
                displayHardwareMatchingCallback,
                Unmanaged.passUnretained(self).toOpaque(),
                &iterator
            )
            guard result == KERN_SUCCESS else {
                AppLogger.ui.error(
                    "Unable to register display hardware event \(event.rawValue, privacy: .public): \(result, privacy: .public)"
                )
                continue
            }
            iterators[iterator] = event
            drain(iterator: iterator, event: event)
        }

        guard !iterators.isEmpty else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        for iterator in iterators.keys {
            IOObjectRelease(iterator)
        }
        iterators.removeAll()
        knownLocations.removeAll()
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    func externalServiceCount() -> Int? {
        guard let matching = IOServiceMatching(Self.serviceClass) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var count = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            if Self.location(of: service) == .external {
                count += 1
            }
            IOObjectRelease(service)
        }
        return count
    }

    fileprivate func receive(iterator: io_iterator_t) {
        guard let event = iterators[iterator] else { return }
        drain(iterator: iterator, event: event)
    }

    private func drain(iterator: io_iterator_t, event: ServiceEvent) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }

            let registryID = Self.registryID(of: service)
            let reportedLocation = Self.location(of: service)
            let location = reportedLocation == .unknown
                ? knownLocations[registryID] ?? .unknown
                : reportedLocation

            switch event {
            case .matched:
                knownLocations[registryID] = location
                send(location == .external ? .externalServiceAdded : .displayServiceChanged)
            case .terminated:
                knownLocations[registryID] = nil
                send(location == .external ? .externalServiceRemoved : .displayServiceChanged)
            }
            IOObjectRelease(service)
        }
    }

    private func send(_ event: DisplayHardwareTopologyEvent) {
        Task { @MainActor [handler] in
            handler(event)
        }
    }

    private static func registryID(of service: io_service_t) -> UInt64 {
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)
        return registryID
    }

    private static func location(of service: io_service_t) -> DisplayHardwareServiceLocation {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "Location" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return .unknown
        }
        return DisplayHardwareServiceLocation(rawValue: value)
    }

    deinit {
        stop()
    }
}

nonisolated(unsafe) private let displayHardwareMatchingCallback: IOServiceMatchingCallback = {
    refcon,
    iterator
in
    guard let refcon else { return }
    Unmanaged<DisplayHardwareTopologyBridge>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .receive(iterator: iterator)
}
