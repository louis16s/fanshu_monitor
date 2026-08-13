import CoreGraphics
import Foundation
import OSLog

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

nonisolated enum DisplayWakeMaintenancePolicy {
    /// WindowServer and the external DCP service become ready at different
    /// points during wake. These bounded retries run only for a wake event.
    static let earlyRetryDelays: [TimeInterval] = [0, 0.03, 0.08, 0.16, 0.3, 0.55]
    static let settledRetryDelays: [TimeInterval] = [0, 0.08, 0.2, 0.45, 0.8]

    static func shouldVerifyExternalDisconnect(isSystemSleeping: Bool) -> Bool {
        !isSystemSleeping
    }
}

/// Owns external-first topology maintenance independently from MainActor.
/// Wake notifications and hardware connection events share one sequential
/// retry state machine, so only one WindowServer request can be in flight.
nonisolated final class DisplayTopologyMaintenanceCoordinator: @unchecked Sendable {
    private enum Phase: Sendable {
        case early
        case settled
        case externalConnection
    }

    private struct State {
        var generation = 0
        var sequenceActive = false
        var settledRequested = false
        var wakeSucceeded = false
    }

    private let blackoutDesired: @Sendable () -> Bool
    private let reapplyTopology: @Sendable (@escaping @Sendable (Set<CGDirectDisplayID>) -> Void) -> Void
    private let topologyApplied: @Sendable (Set<CGDirectDisplayID>) -> Void
    private let schedulingQueue = DispatchQueue(
        label: "fanshu.display-control.wake-topology",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private var state = State()

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
            beginWakeCycle()
        case .hasPoweredOn:
            requestSettledSequence()
        }
    }

    func requestExternalConnectionMaintenance() {
        guard blackoutDesired() else {
            cancel()
            return
        }
        let generation = stateLock.withLock { () -> Int? in
            guard !state.sequenceActive else { return nil }
            state.generation &+= 1
            state.sequenceActive = true
            state.settledRequested = false
            return state.generation
        }
        guard let generation else { return }
        scheduleAttempt(
            phase: .externalConnection,
            delays: DisplayExternalConnectionPolicy.topologyRetryDelays,
            index: 0,
            generation: generation
        )
    }

    func cancel() {
        stateLock.withLock {
            state.generation &+= 1
            state.sequenceActive = false
            state.settledRequested = false
            state.wakeSucceeded = false
        }
    }

    var isRunning: Bool {
        stateLock.withLock { state.sequenceActive }
    }

    private func beginWakeCycle() {
        guard blackoutDesired() else {
            cancel()
            return
        }
        let generation = stateLock.withLock { () -> Int in
            state.generation &+= 1
            state.sequenceActive = true
            state.settledRequested = false
            state.wakeSucceeded = false
            return state.generation
        }
        scheduleAttempt(
            phase: .early,
            delays: DisplayWakeMaintenancePolicy.earlyRetryDelays,
            index: 0,
            generation: generation
        )
    }

    private func requestSettledSequence() {
        guard blackoutDesired() else {
            cancel()
            return
        }
        let generation = stateLock.withLock { () -> Int? in
            guard !state.wakeSucceeded else { return nil }
            if state.sequenceActive {
                state.settledRequested = true
                return nil
            }
            state.generation &+= 1
            state.sequenceActive = true
            state.settledRequested = false
            return state.generation
        }
        guard let generation else { return }
        scheduleAttempt(
            phase: .settled,
            delays: DisplayWakeMaintenancePolicy.settledRetryDelays,
            index: 0,
            generation: generation
        )
    }

    private func scheduleAttempt(
        phase: Phase,
        delays: [TimeInterval],
        index: Int,
        generation: Int
    ) {
        guard index < delays.count else {
            finishSequence(phase: phase, generation: generation)
            return
        }
        let delay = index == 0 ? delays[index] : max(0, delays[index] - delays[index - 1])
        schedulingQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            guard self.blackoutDesired() else {
                self.cancel()
                return
            }
            self.reapplyTopology { [weak self] displayIDs in
                guard let self, self.isCurrent(generation) else { return }
                guard displayIDs.isEmpty else {
                    self.finishSuccessfully(
                        displayIDs,
                        phase: phase,
                        generation: generation
                    )
                    return
                }
                self.scheduleAttempt(
                    phase: phase,
                    delays: delays,
                    index: index + 1,
                    generation: generation
                )
            }
        }
    }

    private func finishSequence(phase: Phase, generation: Int) {
        let shouldStartSettled = stateLock.withLock { () -> Bool in
            guard state.generation == generation else { return false }
            state.sequenceActive = false
            guard phase == .early, state.settledRequested else { return false }
            state.settledRequested = false
            state.sequenceActive = true
            return true
        }
        guard shouldStartSettled else { return }
        scheduleAttempt(
            phase: .settled,
            delays: DisplayWakeMaintenancePolicy.settledRetryDelays,
            index: 0,
            generation: generation
        )
    }

    private func finishSuccessfully(
        _ displayIDs: Set<CGDirectDisplayID>,
        phase: Phase,
        generation: Int
    ) {
        let shouldPublish = stateLock.withLock { () -> Bool in
            guard state.generation == generation else { return false }
            state.sequenceActive = false
            state.settledRequested = false
            if phase != .externalConnection {
                state.wakeSucceeded = true
            }
            return true
        }
        guard shouldPublish else { return }
        topologyApplied(displayIDs)
        switch phase {
        case .early, .settled:
            AppLogger.displayTopology.notice(
                "Restored external-first topology through wake coordination"
            )
        case .externalConnection:
            AppLogger.displayTopology.notice(
                "Restored external-first topology after external display connection"
            )
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        stateLock.withLock {
            state.generation == generation && state.sequenceActive
        }
    }
}
