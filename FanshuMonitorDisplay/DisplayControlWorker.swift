import CoreGraphics
import Foundation

nonisolated enum DisplayWriteMode: Sendable {
    case coalesced
    case ordered
}

nonisolated final class DisplayControlWorker: @unchecked Sendable {
    private struct PendingWrite: Sendable {
        let value: Double
        let sequence: UInt64
        let performWrite: @Sendable (Double) -> Bool
        let completion: @Sendable (DisplayWriteResult) -> Void
    }

    private struct DiscoveryRequest: Sendable {
        let activeControls: Set<DisplayControlKind>
        let performDiscovery: @Sendable () -> [ControlledDisplay]
        var completions: [@Sendable ([ControlledDisplay]) -> Void]
    }

    private struct ActiveDiscovery: Sendable {
        let id: UInt64
        let generation: UInt64
        var request: DiscoveryRequest
    }

    private let stateQueue = DispatchQueue(label: "fanshu.display-control.state", qos: .userInitiated)
    private let discoveryQueue = DispatchQueue(
        label: "fanshu.display-control.discovery",
        qos: .utility
    )
    private let topologyQueue = DispatchQueue(
        label: "fanshu.display-control.topology",
        qos: .userInitiated
    )
    private var writeQueuesByDisplayID: [CGDirectDisplayID: DispatchQueue] = [:]
    private var pendingWrites: [ControlKey: PendingWrite] = [:]
    private var debounceTimers: [ControlKey: DispatchWorkItem] = [:]
    private var debounceGenerations: [ControlKey: UInt64] = [:]
    private var activeOrderedWriteKeys: Set<ControlKey> = []
    private var latestOrderedWrites: [ControlKey: PendingWrite] = [:]
    private var discoveryGeneration: UInt64 = 0
    private var nextDiscoveryID: UInt64 = 0
    private var activeDiscovery: ActiveDiscovery?
    private var pendingDiscovery: DiscoveryRequest?
    private var cachedDiscovery: (
        displays: [ControlledDisplay],
        activeControls: Set<DisplayControlKind>,
        refreshedAt: Date
    )?
    private let debounceInterval: DispatchTimeInterval = .milliseconds(150)
    private let discoveryCacheInterval: TimeInterval = 2

    func refresh(
        service: DisplayControlService,
        activeControls: Set<DisplayControlKind>,
        completion: @escaping @Sendable ([ControlledDisplay]) -> Void
    ) {
        refresh(
            activeControls: activeControls,
            performDiscovery: {
                service.displays(reading: activeControls)
            },
            completion: completion
        )
    }

    func refresh(
        activeControls: Set<DisplayControlKind>,
        performDiscovery: @escaping @Sendable () -> [ControlledDisplay],
        completion: @escaping @Sendable ([ControlledDisplay]) -> Void
    ) {
        stateQueue.async {
            let now = Date()
            if let cachedDiscovery = self.cachedDiscovery,
               cachedDiscovery.activeControls == activeControls,
               now.timeIntervalSince(cachedDiscovery.refreshedAt) < self.discoveryCacheInterval {
                completion(cachedDiscovery.displays)
                return
            }

            let request = DiscoveryRequest(
                activeControls: activeControls,
                performDiscovery: performDiscovery,
                completions: [completion]
            )
            if var active = self.activeDiscovery {
                if active.generation == self.discoveryGeneration,
                   active.request.activeControls == activeControls,
                   self.pendingDiscovery == nil {
                    active.request.completions.append(completion)
                    self.activeDiscovery = active
                } else {
                    self.enqueuePendingDiscovery(request)
                }
                return
            }
            self.startDiscovery(request)
        }
    }

    private func startDiscovery(_ request: DiscoveryRequest) {
        nextDiscoveryID &+= 1
        let active = ActiveDiscovery(
            id: nextDiscoveryID,
            generation: discoveryGeneration,
            request: request
        )
        activeDiscovery = active
        discoveryQueue.async {
            let displays = request.performDiscovery()
            self.stateQueue.async {
                self.finishDiscovery(id: active.id, displays: displays)
            }
        }
    }

    private func finishDiscovery(id: UInt64, displays: [ControlledDisplay]) {
        guard let active = activeDiscovery, active.id == id else { return }
        activeDiscovery = nil
        if active.generation == discoveryGeneration {
            cachedDiscovery = (
                displays,
                active.request.activeControls,
                Date()
            )
            active.request.completions.forEach { $0(displays) }
        }
        if let pendingDiscovery {
            self.pendingDiscovery = nil
            startDiscovery(pendingDiscovery)
        }
    }

    private func enqueuePendingDiscovery(_ request: DiscoveryRequest) {
        guard let pendingDiscovery else {
            self.pendingDiscovery = request
            return
        }
        self.pendingDiscovery = DiscoveryRequest(
            activeControls: request.activeControls,
            performDiscovery: request.performDiscovery,
            completions: pendingDiscovery.completions + request.completions
        )
    }

    func readNativeBrightness(
        displayID: CGDirectDisplayID,
        performRead: @escaping @Sendable () -> Double?,
        completion: @escaping @Sendable (Double?) -> Void
    ) {
        stateQueue.async {
            let readQueue = self.writeQueue(for: displayID)
            readQueue.async {
                let value = performRead()
                completion(value)
            }
        }
    }

    func setBuiltInBlackout(
        _ enabled: Bool,
        display: ControlledDisplay,
        displays: [ControlledDisplay],
        service: DisplayControlService,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        topologyQueue.async {
            completion(service.setBuiltInBlackout(enabled, display: display, displays: displays))
        }
    }

    func reapplyBuiltInBlackouts(
        service: DisplayControlService,
        completion: @escaping @Sendable (Set<CGDirectDisplayID>) -> Void
    ) {
        topologyQueue.async {
            completion(service.reapplyBuiltInBlackoutsToOnlineDisplays())
        }
    }

    func clearBuiltInBlackouts(
        service: DisplayControlService,
        completion: @escaping @Sendable () -> Void
    ) {
        topologyQueue.async {
            service.clearBuiltInBlackouts()
            completion()
        }
    }

    func restoreBuiltInAfterExternalDisconnect(
        brightnessPercent: Double,
        forceRestore: Bool = false,
        service: DisplayControlService,
        completion: @escaping @Sendable (BuiltInDisconnectRecoveryResult) -> Void
    ) {
        restoreBuiltInAfterExternalDisconnect(
            brightnessPercent: brightnessPercent,
            forceRestore: forceRestore,
            topologyRetryDelays: BuiltInDisplayRestorePolicy.topologyRetryDelays,
            brightnessRetryDelays: BuiltInDisplayRestorePolicy.brightnessRetryDelays,
            hasExternalDisplay: { service.hasUsableExternalDisplay() },
            restoreTopology: { brightness in
                service.clearBuiltInBlackouts(restoredBrightnessOverride: brightness)
            },
            applyBrightness: { brightness, displayID in
                service.setBuiltInBrightness(brightness, displayID: displayID)
            },
            completion: completion
        )
    }

    func restoreBuiltInAfterExternalDisconnect(
        brightnessPercent: Double,
        forceRestore: Bool = false,
        topologyRetryDelays: [TimeInterval],
        brightnessRetryDelays: [TimeInterval],
        hasExternalDisplay: @escaping @Sendable () -> Bool,
        restoreTopology: @escaping @Sendable (Float) -> CGDirectDisplayID?,
        applyBrightness: @escaping @Sendable (Float, CGDirectDisplayID) -> Bool,
        completion: @escaping @Sendable (BuiltInDisconnectRecoveryResult) -> Void
    ) {
        topologyQueue.async {
            let brightness = Float(min(100, max(0, brightnessPercent)) / 100)
            self.restoreBuiltInTopology(
                brightness,
                forceRestore: forceRestore,
                retryIndex: 0,
                topologyRetryDelays: topologyRetryDelays,
                brightnessRetryDelays: brightnessRetryDelays,
                hasExternalDisplay: hasExternalDisplay,
                restoreTopology: restoreTopology,
                applyBrightness: applyBrightness,
                completion: completion
            )
        }
    }

    private func restoreBuiltInTopology(
        _ brightness: Float,
        forceRestore: Bool,
        retryIndex: Int,
        topologyRetryDelays: [TimeInterval],
        brightnessRetryDelays: [TimeInterval],
        hasExternalDisplay: @escaping @Sendable () -> Bool,
        restoreTopology: @escaping @Sendable (Float) -> CGDirectDisplayID?,
        applyBrightness: @escaping @Sendable (Float, CGDirectDisplayID) -> Bool,
        completion: @escaping @Sendable (BuiltInDisconnectRecoveryResult) -> Void
    ) {
        guard retryIndex < topologyRetryDelays.count else {
            completion(.builtInDisplayUnavailable)
            return
        }
        topologyQueue.asyncAfter(deadline: .now() + topologyRetryDelays[retryIndex]) {
            guard forceRestore || !hasExternalDisplay() else {
                completion(.externalDisplayPresent)
                return
            }
            guard let displayID = restoreTopology(brightness) else {
                self.restoreBuiltInTopology(
                    brightness,
                    forceRestore: forceRestore,
                    retryIndex: retryIndex + 1,
                    topologyRetryDelays: topologyRetryDelays,
                    brightnessRetryDelays: brightnessRetryDelays,
                    hasExternalDisplay: hasExternalDisplay,
                    restoreTopology: restoreTopology,
                    applyBrightness: applyBrightness,
                    completion: completion
                )
                return
            }
            self.applyRestoredBuiltInBrightness(
                brightness,
                displayID: displayID,
                retryIndex: 0,
                retryDelays: brightnessRetryDelays,
                applyBrightness: applyBrightness,
                completion: completion
            )
        }
    }

    private func applyRestoredBuiltInBrightness(
        _ brightness: Float,
        displayID: CGDirectDisplayID,
        retryIndex: Int,
        retryDelays: [TimeInterval],
        applyBrightness: @escaping @Sendable (Float, CGDirectDisplayID) -> Bool,
        completion: @escaping @Sendable (BuiltInDisconnectRecoveryResult) -> Void
    ) {
        guard retryIndex < retryDelays.count else {
            completion(.brightnessPending(displayID: displayID))
            return
        }
        topologyQueue.asyncAfter(deadline: .now() + retryDelays[retryIndex]) {
            if applyBrightness(brightness, displayID) {
                completion(.restored(displayID: displayID))
            } else {
                self.applyRestoredBuiltInBrightness(
                    brightness,
                    displayID: displayID,
                    retryIndex: retryIndex + 1,
                    retryDelays: retryDelays,
                    applyBrightness: applyBrightness,
                    completion: completion
                )
            }
        }
    }

    func invalidateDiscoveryCache() {
        stateQueue.async {
            self.discoveryGeneration &+= 1
            self.cachedDiscovery = nil
            guard var active = self.activeDiscovery,
                  !active.request.completions.isEmpty else {
                return
            }
            let staleCompletions = active.request.completions
            active.request.completions.removeAll()
            self.activeDiscovery = active
            if var pendingDiscovery = self.pendingDiscovery {
                pendingDiscovery.completions = staleCompletions + pendingDiscovery.completions
                self.pendingDiscovery = pendingDiscovery
            } else {
                self.pendingDiscovery = DiscoveryRequest(
                    activeControls: active.request.activeControls,
                    performDiscovery: active.request.performDiscovery,
                    completions: staleCompletions
                )
            }
        }
    }

    func setValue(
        _ value: Double,
        for key: ControlKey,
        sequence: UInt64,
        mode: DisplayWriteMode,
        performWrite: @escaping @Sendable (Double) -> Bool,
        completion: @escaping @Sendable (DisplayWriteResult) -> Void
    ) {
        stateQueue.async {
            switch mode {
            case .ordered:
                self.cancelPendingWrite(for: key)
                self.scheduleOrderedWrite(
                    PendingWrite(
                        value: value,
                        sequence: sequence,
                        performWrite: performWrite,
                        completion: completion
                    ),
                    for: key
                )
            case .coalesced:
                self.latestOrderedWrites[key] = nil
                self.scheduleCoalescedWrite(
                    PendingWrite(
                        value: value,
                        sequence: sequence,
                        performWrite: performWrite,
                        completion: completion
                    ),
                    for: key
                )
            }
        }
    }

    private func scheduleCoalescedWrite(_ request: PendingWrite, for key: ControlKey) {
        pendingWrites[key] = request
        debounceTimers[key]?.cancel()

        let generation = (debounceGenerations[key] ?? 0) &+ 1
        debounceGenerations[key] = generation
        let timer = DispatchWorkItem { [weak self] in
            guard let self,
                  self.debounceGenerations[key] == generation,
                  let latestRequest = self.pendingWrites.removeValue(forKey: key)
            else {
                return
            }
            self.debounceTimers[key] = nil
            self.debounceGenerations[key] = nil

            self.perform(latestRequest, for: key)
        }
        debounceTimers[key] = timer
        stateQueue.asyncAfter(deadline: .now() + debounceInterval, execute: timer)
    }

    private func cancelPendingWrite(for key: ControlKey) {
        debounceTimers[key]?.cancel()
        debounceTimers[key] = nil
        debounceGenerations[key] = nil
        pendingWrites[key] = nil
    }

    private func scheduleOrderedWrite(_ request: PendingWrite, for key: ControlKey) {
        guard !activeOrderedWriteKeys.contains(key) else {
            latestOrderedWrites[key] = request
            return
        }
        activeOrderedWriteKeys.insert(key)
        performOrderedWrite(request, for: key)
    }

    private func performOrderedWrite(_ request: PendingWrite, for key: ControlKey) {
        let writeQueue = writeQueue(for: key.displayID)
        writeQueue.async {
            let success = request.performWrite(request.value)
            request.completion(
                DisplayWriteResult(
                    key: key,
                    value: request.value,
                    sequence: request.sequence,
                    success: success
                )
            )
            self.stateQueue.async {
                if let latest = self.latestOrderedWrites.removeValue(forKey: key) {
                    self.performOrderedWrite(latest, for: key)
                } else {
                    self.activeOrderedWriteKeys.remove(key)
                }
            }
        }
    }

    private func perform(_ request: PendingWrite, for key: ControlKey) {
        let writeQueue = writeQueue(for: key.displayID)
        writeQueue.async {
            let success = request.performWrite(request.value)
            request.completion(
                DisplayWriteResult(
                    key: key,
                    value: request.value,
                    sequence: request.sequence,
                    success: success
                )
            )
        }
    }

    private func writeQueue(for displayID: CGDirectDisplayID) -> DispatchQueue {
        if let queue = writeQueuesByDisplayID[displayID] {
            return queue
        }
        let queue = DispatchQueue(
            label: "fanshu.display-control.write.\(displayID)",
            qos: .userInitiated
        )
        writeQueuesByDisplayID[displayID] = queue
        return queue
    }
}

nonisolated struct DisplayWriteResult: Sendable {
    let key: ControlKey
    let value: Double
    let sequence: UInt64
    let success: Bool
}
