import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

nonisolated private let messageCanSystemSleep: natural_t = 0xe000_0270
nonisolated private let messageSystemWillSleep: natural_t = 0xe000_0280
nonisolated private let messageSystemHasPoweredOn: natural_t = 0xe000_0300
nonisolated private let messageSystemWillPowerOn: natural_t = 0xe000_0320

nonisolated enum DisplayPowerEvent: Sendable {
    case willSleep
    case willPowerOn
    case hasPoweredOn
}

nonisolated final class DisplayBlackoutIntentState: @unchecked Sendable {
    private let lock = NSLock()
    private var desired: Bool

    init(desired: Bool) {
        self.desired = desired
    }

    var isDesired: Bool {
        lock.withLock { desired }
    }

    func setDesired(_ desired: Bool) {
        lock.withLock {
            self.desired = desired
        }
    }
}

/// Reapplies the persisted external-first topology before AppKit and SwiftUI
/// resume. LoginWindow can choose a display before the app's main run loop is
/// serviced, so this path must remain independent from MainActor.
nonisolated final class DisplayEarlyWakeTopologyMaintainer: @unchecked Sendable {
    private let blackoutDesired: @Sendable () -> Bool
    private let reapplyTopology: @Sendable (@escaping @Sendable (Set<CGDirectDisplayID>) -> Void) -> Void
    private let topologyApplied: @Sendable (Set<CGDirectDisplayID>) -> Void
    private let schedulingQueue = DispatchQueue(
        label: "fanshu.display-control.early-wake",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var generation = 0

    init(
        worker: DisplayControlWorker,
        service: DisplayControlService,
        blackoutDesired: @escaping @Sendable () -> Bool,
        topologyApplied: @escaping @Sendable (Set<CGDirectDisplayID>) -> Void
    ) {
        self.blackoutDesired = blackoutDesired
        reapplyTopology = { completion in
            worker.reapplyBuiltInBlackouts(service: service, completion: completion)
        }
        self.topologyApplied = topologyApplied
    }

    init(
        blackoutDesired: @escaping @Sendable () -> Bool,
        reapplyTopology: @escaping @Sendable (@escaping @Sendable (Set<CGDirectDisplayID>) -> Void) -> Void,
        topologyApplied: @escaping @Sendable (Set<CGDirectDisplayID>) -> Void
    ) {
        self.blackoutDesired = blackoutDesired
        self.reapplyTopology = reapplyTopology
        self.topologyApplied = topologyApplied
    }

    func handle(_ event: DisplayPowerEvent) {
        switch event {
        case .willSleep:
            cancel()
        case .willPowerOn:
            schedule(delays: DisplayWakeMaintenancePolicy.earlyRetryDelays)
        case .hasPoweredOn:
            schedule(delays: DisplayWakeMaintenancePolicy.settledRetryDelays)
        }
    }

    func cancel() {
        stateLock.withLock {
            generation &+= 1
        }
    }

    private func schedule(delays: [TimeInterval]) {
        guard blackoutDesired() else {
            cancel()
            return
        }
        let currentGeneration = stateLock.withLock { () -> Int in
            generation &+= 1
            return generation
        }

        for delay in delays {
            schedulingQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isCurrent(currentGeneration),
                      self.blackoutDesired()
                else {
                    return
                }
                self.reapplyTopology { [weak self] displayIDs in
                    guard let self,
                          self.isCurrent(currentGeneration),
                          !displayIDs.isEmpty
                    else {
                        return
                    }
                    self.cancel()
                    self.topologyApplied(displayIDs)
                    AppLogger.displayTopology.notice(
                        "Restored external-first topology through early wake maintenance"
                    )
                }
            }
        }
    }

    private func isCurrent(_ candidate: Int) -> Bool {
        stateLock.withLock { generation == candidate }
    }
}

nonisolated enum DisplayWakeMaintenancePolicy {
    /// The external DCP service and WindowServer display appear at different
    /// points during wake. Fast bounded retries cover both without polling.
    static let earlyRetryDelays: [TimeInterval] = [0, 0.03, 0.08, 0.16, 0.3, 0.55]
    static let settledRetryDelays: [TimeInterval] = [0, 0.08, 0.2, 0.45, 0.8]

    static func shouldVerifyExternalDisconnect(isSystemSleeping: Bool) -> Bool {
        !isSystemSleeping
    }
}

nonisolated final class DisplayPowerEventBridge: @unchecked Sendable {
    private let earlyHandler: @Sendable (DisplayPowerEvent) -> Void
    private let handler: @MainActor @Sendable (DisplayPowerEvent) -> Void
    private let deliveryQueue = DispatchQueue(
        label: "fanshu.display-control.power-events",
        qos: .userInteractive
    )
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(
        earlyHandler: @escaping @Sendable (DisplayPowerEvent) -> Void = { _ in },
        handler: @escaping @MainActor @Sendable (DisplayPowerEvent) -> Void
    ) {
        self.earlyHandler = earlyHandler
        self.handler = handler
    }

    func start() {
        guard rootPort == 0 else { return }

        var port: IONotificationPortRef?
        var notification: io_object_t = 0
        let connection = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &port,
            displayPowerCallback,
            &notification
        )
        guard connection != 0, let port else {
            AppLogger.ui.error("Unable to register early display power notifications")
            return
        }

        rootPort = connection
        notificationPort = port
        notifier = notification
        IONotificationPortSetDispatchQueue(port, deliveryQueue)
    }

    func stop() {
        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    fileprivate func receive(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case messageCanSystemSleep, messageSystemWillSleep:
            if messageType == messageSystemWillSleep {
                send(.willSleep)
            }
            if let argument {
                IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            }
        case messageSystemWillPowerOn:
            send(.willPowerOn)
        case messageSystemHasPoweredOn:
            send(.hasPoweredOn)
        default:
            break
        }
    }

    private func send(_ event: DisplayPowerEvent) {
        earlyHandler(event)
        Task { @MainActor [handler] in
            handler(event)
        }
    }

    deinit {
        stop()
    }
}

nonisolated(unsafe) private let displayPowerCallback: IOServiceInterestCallback = {
    refcon,
    _,
    messageType,
    messageArgument
in
    guard let refcon else { return }
    Unmanaged<DisplayPowerEventBridge>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .receive(messageType: messageType, argument: messageArgument)
}
