import AppKit
import Combine
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class DisplayControlController: ObservableObject {
    @Published private(set) var displays: [ControlledDisplay] = []
    @Published private var builtInBlackoutDisplayIDs: Set<CGDirectDisplayID> = []
    @Published private(set) var builtInBlackoutActionFailed = false
    @Published private(set) var builtInBlackoutOperationPending = false
    @Published private var pendingValues: [CGDirectDisplayID: [DisplayControlKind: Double]] = [:]

    private static let builtInBlackoutPreferenceKey = "displayControl.builtInBlackoutDesired"
    private let service = DisplayControlService()
    private let worker = DisplayControlWorker()
    private let defaults = UserDefaults.standard
    private var fallbackValues: [CGDirectDisplayID: [DisplayControlKind: Double]] = [:]
    private var recentWrittenValues: [ControlKey: RecentDisplayValue] = [:]
    private var latestWriteSequences: [ControlKey: UInt64] = [:]
    private var latestConfirmedWriteSequences: [ControlKey: UInt64] = [:]
    private var nextWriteSequence: UInt64 = 0
    private var screenChangeObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    private var screensDidWakeObserver: NSObjectProtocol?
    private var powerEventBridge: DisplayPowerEventBridge?
    private var hardwareTopologyMonitor: DisplayHardwareTopologyMonitor?
    private var refreshWorkItem: DispatchWorkItem?
    private var wakeRefreshGeneration = 0
    private var displayCallbackRegistered = false
    private var isPanelVisible = false
    private var nativeBrightnessSyncTask: Task<Void, Never>?
    private var nativeBrightnessSyncGeneration = 0
    private var nativeBrightnessReadsInFlight: Set<CGDirectDisplayID> = []
    private var cachedBuiltInDisplay: ControlledDisplay?
    private var lastKnownExternalDisplayIDs: Set<CGDirectDisplayID> = []
    private var builtInDisconnectRecoveryPending = false
    private var builtInBlackoutSuspendedForMissingExternal = false
    private var builtInDisconnectWatchdogTask: Task<Void, Never>?
    private var builtInDisconnectWatchdogGeneration = 0
    private var isSystemSleeping = false
    private lazy var blackoutIntentState = DisplayBlackoutIntentState(
        desired: defaults.bool(forKey: Self.builtInBlackoutPreferenceKey)
    )
    private lazy var topologyMaintenanceCoordinator = DisplayTopologyMaintenanceCoordinator(
        worker: worker,
        service: service,
        blackoutDesired: { [blackoutIntentState] in
            blackoutIntentState.isDesired
        },
        topologyApplied: { [weak self] displayIDs in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.builtInBlackoutDisplayIDs.formUnion(displayIDs)
                self.builtInBlackoutActionFailed = false
                self.builtInBlackoutSuspendedForMissingExternal = false
                self.scheduleRefresh(delay: 0.03)
            }
        }
    )
    private var isBuiltInBlackoutDesired: Bool {
        get {
            defaults.bool(forKey: Self.builtInBlackoutPreferenceKey)
        }
        set {
            defaults.set(newValue, forKey: Self.builtInBlackoutPreferenceKey)
            blackoutIntentState.setDesired(newValue)
            if !newValue {
                topologyMaintenanceCoordinator.cancel()
            }
            configureBuiltInDisconnectWatchdog()
        }
    }
    var needsBuiltInBlackoutMaintenance: Bool {
        isBuiltInBlackoutDesired
            || !builtInBlackoutDisplayIDs.isEmpty
            || service.hasOfflineCachedBuiltInDisplay()
    }
    weak var settings: MonitorSettings? {
        didSet {
            service.softwareDimmingEnabled = settings?.displaySoftwareDimmingEnabled ?? true
            if service.softwareDimmingEnabled {
                syncSoftwareDimming()
            } else {
                service.clearSoftwareDimming()
            }
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        if let didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(didWakeObserver)
        }
        if let screensDidWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensDidWakeObserver)
        }
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
        nativeBrightnessSyncTask?.cancel()
        builtInDisconnectWatchdogTask?.cancel()
        powerEventBridge?.stop()
        Task { @MainActor [service] in
            service.clearBuiltInBlackouts()
            service.clearSoftwareDimming()
        }
    }

    func refreshAsync() {
        let controls = activeControls
        worker.refresh(service: service, activeControls: controls) { detectedDisplays in
            DispatchQueue.main.async {
                AppLogger.ui.info("Display refresh completed, found \(detectedDisplays.count) displays")
                if let builtInDisplay = detectedDisplays.first(where: \.isBuiltIn) {
                    self.cachedBuiltInDisplay = builtInDisplay
                }
                let detectedExternalDisplayIDs = Set(
                    detectedDisplays.lazy.filter { !$0.isBuiltIn }.map(\.id)
                )
                if !detectedExternalDisplayIDs.isEmpty {
                    self.lastKnownExternalDisplayIDs = detectedExternalDisplayIDs
                }
                let restoredBuiltInDisplayIDs = self.service.reconcileRestoredBuiltInDisplays(
                    candidates: self.builtInBlackoutDisplayIDs
                )
                if !restoredBuiltInDisplayIDs.isEmpty {
                    self.builtInBlackoutDisplayIDs.subtract(restoredBuiltInDisplayIDs)
                    AppLogger.ui.notice(
                        "Reconciled externally restored built-in displays: \(restoredBuiltInDisplayIDs.map { String($0) }.joined(separator: ","), privacy: .public)"
                    )
                }
                var mergedDisplays = detectedDisplays.map { detectedDisplay in
                    var display = self.mergedDisplayValues(for: detectedDisplay)
                    if self.settings?.displayCapabilitiesEnabled == true {
                        display.capabilities = DisplayCapabilityProbe.snapshot(
                            displayID: display.id,
                            kind: display.kind
                        )
                    }
                    return display
                }
                let cachedBuiltInRow = self.cachedBuiltInDisplay
                    ?? self.service.isolatedBuiltInPlaceholder()
                if BuiltInDisplayPresentationPolicy.shouldKeepCachedRow(
                    detectedBuiltInCount: mergedDisplays.filter(\.isBuiltIn).count,
                    blackoutDesired: self.isBuiltInBlackoutDesired,
                    isolatedDisplayCount: self.builtInBlackoutDisplayIDs.count,
                    hasCachedDisplay: cachedBuiltInRow != nil
                ),
                   !mergedDisplays.contains(where: \.isBuiltIn),
                   var cachedBuiltInDisplay = cachedBuiltInRow {
                    cachedBuiltInDisplay.brightness = 0
                    cachedBuiltInDisplay.supportsBrightness = false
                    cachedBuiltInDisplay.brightnessUnavailableReason = "已关闭"
                    mergedDisplays.insert(cachedBuiltInDisplay, at: 0)
                    self.cachedBuiltInDisplay = cachedBuiltInDisplay
                    self.builtInBlackoutDisplayIDs.insert(cachedBuiltInDisplay.id)
                    AppLogger.ui.info(
                        "Merged isolated built-in display row with ID \(cachedBuiltInDisplay.id)"
                    )
                }
                self.displays = mergedDisplays
                for display in mergedDisplays {
                    self.seedFallbackValues(for: display)
                }
                self.syncBuiltInBlackouts()
                self.syncSoftwareDimming()
                self.configureNativeBrightnessSync()
            }
        }
    }

    func refreshNow() {
        refreshWorkItem?.cancel()
        worker.invalidateDiscoveryCache()
        refreshAsync()
    }

    func isBuiltInBlackoutEnabled(displayID: CGDirectDisplayID) -> Bool {
        builtInBlackoutDisplayIDs.contains(displayID)
    }

    func toggleBuiltInBlackout(displayID: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == displayID }),
              display.isBuiltIn
        else {
            AppLogger.ui.error("Ignored built-in display toggle because display ID \(displayID) is unavailable")
            return
        }

        let shouldEnable = !builtInBlackoutDisplayIDs.contains(displayID)
        guard !builtInBlackoutOperationPending else {
            AppLogger.ui.debug("Ignored duplicate built-in display topology request")
            return
        }
        builtInBlackoutActionFailed = false
        builtInBlackoutOperationPending = true
        AppLogger.ui.notice(
            "Requesting built-in display blackout: \(shouldEnable, privacy: .public), display ID: \(displayID)"
        )
        worker.setBuiltInBlackout(
            shouldEnable,
            display: display,
            displays: displays,
            service: service
        ) { [self] succeeded in
            Task { @MainActor [self] in
                self.builtInBlackoutOperationPending = false
                self.builtInBlackoutActionFailed = !succeeded
                guard succeeded else {
                    AppLogger.ui.error(
                        "Built-in display topology request failed, blackout: \(shouldEnable, privacy: .public), display ID: \(displayID)"
                    )
                    self.scheduleRefresh(delay: 0.2)
                    return
                }
                if shouldEnable {
                    self.cachedBuiltInDisplay = display
                    self.builtInBlackoutSuspendedForMissingExternal = false
                    self.isBuiltInBlackoutDesired = true
                    self.builtInBlackoutDisplayIDs.insert(displayID)
                } else {
                    self.builtInBlackoutSuspendedForMissingExternal = false
                    self.isBuiltInBlackoutDesired = false
                    self.builtInBlackoutDisplayIDs.remove(displayID)
                }
                AppLogger.ui.notice(
                    "Built-in display topology request completed, blackout: \(shouldEnable, privacy: .public), display ID: \(displayID)"
                )
                self.scheduleRefresh(delay: 0.2)
            }
        }
    }

    func startAutomaticRefresh() {
        if screenChangeObserver == nil {
            screenChangeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let controller = self else { return }
                Task { @MainActor in
                    controller.handleDisplayTopologySignal()
                }
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if didWakeObserver == nil {
            didWakeObserver = workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let controller = self else { return }
                Task { @MainActor in
                    controller.scheduleWakeDiscoveryRefreshes()
                }
            }
        }
        if screensDidWakeObserver == nil {
            screensDidWakeObserver = workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let controller = self else { return }
                Task { @MainActor in
                    controller.scheduleWakeDiscoveryRefreshes()
                }
            }
        }

        if powerEventBridge == nil {
            let topologyMaintenanceCoordinator = topologyMaintenanceCoordinator
            let bridge = DisplayPowerEventBridge(
                earlyHandler: { event in
                    topologyMaintenanceCoordinator.handle(event)
                },
                handler: { [weak self] event in
                    self?.handlePowerEvent(event)
                }
            )
            powerEventBridge = bridge
            bridge.start()
        }

        if hardwareTopologyMonitor == nil {
            let monitor = DisplayHardwareTopologyMonitor(
                topologyChanged: { [weak self] event in
                    self?.handleHardwareTopologyEvent(event)
                },
                lastExternalServiceRemoved: { [weak self] in
                    self?.handleConfirmedExternalHardwareDisconnect()
                }
            )
            if monitor.start() {
                hardwareTopologyMonitor = monitor
                Task { @MainActor [weak self, monitor] in
                    guard let self,
                          self.hardwareTopologyMonitor === monitor,
                          let externalServiceCount = await monitor.externalServiceCount()
                    else { return }
                    AppLogger.ui.notice(
                        "Display hardware monitor started with \(externalServiceCount, privacy: .public) external services"
                    )
                }
            }
        }

        if !displayCallbackRegistered {
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            let result = CGDisplayRegisterReconfigurationCallback(
                displayReconfigurationCallback,
                pointer
            )
            if result == .success {
                displayCallbackRegistered = true
            } else {
                AppLogger.ui.error(
                    "Unable to register display reconfiguration callback: \(result.rawValue, privacy: .public)"
                )
            }
        }
        configureBuiltInDisconnectWatchdog()
        configureNativeBrightnessSync()
    }

    func stopAutomaticRefresh() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        if let didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(didWakeObserver)
            self.didWakeObserver = nil
        }
        if let screensDidWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensDidWakeObserver)
            self.screensDidWakeObserver = nil
        }
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
            displayCallbackRegistered = false
        }
        powerEventBridge?.stop()
        powerEventBridge = nil
        topologyMaintenanceCoordinator.cancel()
        hardwareTopologyMonitor?.stop()
        hardwareTopologyMonitor = nil
        builtInDisconnectWatchdogTask?.cancel()
        builtInDisconnectWatchdogTask = nil
        stopNativeBrightnessSync()
    }

    func prepareBuiltInDisplayForTermination() {
        wakeRefreshGeneration &+= 1
        // Restore the physical topology without clearing the user's next-launch preference.
        service.clearBuiltInBlackouts()
        builtInBlackoutDisplayIDs.removeAll()
        builtInBlackoutOperationPending = false
        builtInBlackoutActionFailed = false
    }

    func setPanelVisible(_ isVisible: Bool) {
        guard isPanelVisible != isVisible else { return }
        isPanelVisible = isVisible
        configureNativeBrightnessSync()
    }

    func scheduleRefresh(delay: TimeInterval = 0.45) {
        refreshWorkItem?.cancel()
        worker.invalidateDiscoveryCache()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshAsync()
            }
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func handleDisplayReconfiguration(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        AppLogger.ui.debug(
            "Display reconfiguration for ID \(displayID), flags: \(flags.rawValue, privacy: .public)"
        )
        let isRemoval = flags.contains(.removeFlag) || flags.contains(.disabledFlag)
        let visibleExternalDisplayIDs = Set(displays.lazy.filter { !$0.isBuiltIn }.map(\.id))
        let knownExternalDisplayIDs = visibleExternalDisplayIDs.isEmpty
            ? lastKnownExternalDisplayIDs
            : visibleExternalDisplayIDs
        let isLastKnownExternalRemoval = DisplayDisconnectRecoveryPolicy.shouldForceRestore(
            isRemoval: isRemoval,
            removedDisplayID: displayID,
            cachedBuiltInDisplayID: cachedBuiltInDisplay?.id,
            knownExternalDisplayIDs: knownExternalDisplayIDs
        )
        scheduleRefresh(delay: isRemoval ? 0.12 : 0.45)
        if isRemoval, displayID == cachedBuiltInDisplay?.id {
            return
        }
        guard needsBuiltInDisconnectRecovery else { return }
        recoverBuiltInDisplayAfterExternalDisconnect(
            triggerDisplayID: displayID,
            forceRestore: isLastKnownExternalRemoval
        )
    }

    private func handleDisplayTopologySignal() {
        scheduleRefresh(delay: 0.12)
        guard needsBuiltInDisconnectRecovery else { return }
        recoverBuiltInDisplayAfterExternalDisconnect(triggerDisplayID: 0)
    }

    private func handleConfirmedExternalHardwareDisconnect() {
        guard DisplayWakeMaintenancePolicy.shouldVerifyExternalDisconnect(
            isSystemSleeping: isSystemSleeping
        ) else {
            return
        }
        scheduleRefresh(delay: 0.15)
        guard requiresPhysicalBuiltInRestore else { return }
        recoverBuiltInDisplayAfterExternalDisconnect(
            triggerDisplayID: 0,
            forceRestore: true
        )
    }

    private func handleHardwareTopologyEvent(_ event: DisplayHardwareTopologyEvent) {
        switch event {
        case .externalServiceAdded:
            scheduleRefresh(delay: DisplayExternalConnectionPolicy.discoveryDelay)
            scheduleExternalConnectionMaintenance()
        case .externalServiceRemoved, .displayServiceChanged:
            scheduleRefresh(delay: 0.15)
        }
    }

    private func scheduleExternalConnectionMaintenance() {
        guard isBuiltInBlackoutDesired else { return }
        worker.invalidateDiscoveryCache()
        builtInBlackoutSuspendedForMissingExternal = false
        topologyMaintenanceCoordinator.requestExternalConnectionMaintenance()
    }

    func scheduleWakeDiscoveryRefreshes(early: Bool = false) {
        AppLogger.ui.notice("Display wake detected; refreshing display inventory")
        worker.invalidateDiscoveryCache()
        if isBuiltInBlackoutDesired {
            // NSWorkspace wake notifications are a fallback for power events
            // that WindowServer can omit after repeated dark-wake cycles.
            topologyMaintenanceCoordinator.requestExternalConnectionMaintenance()
        }
        wakeRefreshGeneration &+= 1
        let generation = wakeRefreshGeneration
        let delays: [TimeInterval] = early
            ? [0.08, 0.35, 0.9]
            : [0.12, 0.6, 1.6]

        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in
                    guard let self, generation == self.wakeRefreshGeneration else { return }
                    self.worker.invalidateDiscoveryCache()
                    self.refreshAsync()
                }
            }
        }
    }

    private func handlePowerEvent(_ event: DisplayPowerEvent) {
        switch event {
        case .willSleep:
            isSystemSleeping = true
            hardwareTopologyMonitor?.setSystemSleeping(true)
            guard isBuiltInBlackoutDesired else { return }
            AppLogger.ui.notice("Preparing isolated built-in display for sleep")
        case .willPowerOn:
            isSystemSleeping = false
            hardwareTopologyMonitor?.setSystemSleeping(false)
            guard isBuiltInBlackoutDesired else { return }
            scheduleWakeDiscoveryRefreshes(early: true)
        case .hasPoweredOn:
            isSystemSleeping = false
            hardwareTopologyMonitor?.setSystemSleeping(false)
            guard isBuiltInBlackoutDesired else { return }
            scheduleWakeDiscoveryRefreshes()
        }
    }

    func displayUnderMouse() -> ControlledDisplay? {
        guard let displayID = primaryDisplayIDUnderMouse() ?? displayIDsUnderMouse().first else { return nil }
        if displays.isEmpty {
            refreshNow()
        }
        return displays.first { $0.id == displayID }
    }

    func brightnessDisplayUnderMouse() -> ControlledDisplay? {
        if let primaryDisplayID = primaryDisplayIDUnderMouse() {
            if displays.isEmpty {
                AppLogger.ui.debug("Brightness key target list is empty; scheduling display refresh")
                refreshNow()
                return nil
            }

            guard let primaryDisplay = displays.first(where: { $0.id == primaryDisplayID }) else {
                AppLogger.ui.debug("Brightness key primary display \(primaryDisplayID) is not in controller list; scheduling display refresh")
                refreshNow()
                return nil
            }

            if primaryDisplay.isBuiltIn {
                AppLogger.ui.debug("Brightness key pass-through: mouse is on built-in display \(primaryDisplayID)")
                return nil
            }

            if primaryDisplay.supports(.brightness) {
                return primaryDisplay
            }

            AppLogger.ui.debug(
                "Brightness key pass-through: primary external display \(primaryDisplayID) does not support brightness, reason: \(primaryDisplay.brightnessUnavailableReason ?? "unknown", privacy: .public)"
            )
            return nil
        }

        let candidateIDs = displayIDsUnderMouse()
        guard !candidateIDs.isEmpty else {
            AppLogger.ui.debug("Brightness key pass-through: no display under mouse")
            return nil
        }
        if displays.isEmpty {
            AppLogger.ui.debug("Brightness key target list is empty; scheduling display refresh")
            refreshNow()
            return nil
        }

        if let target = brightnessTarget(from: candidateIDs) {
            return target
        }

        AppLogger.ui.debug("Brightness key target not ready; scheduling display refresh")
        refreshNow()

        if candidateIDs.contains(where: { candidateID in
            displays.first(where: { $0.id == candidateID })?.isBuiltIn == true
        }) {
            AppLogger.ui.debug("Brightness key pass-through: mouse is on built-in display")
            return nil
        }

        AppLogger.ui.debug("Brightness key pass-through: no controllable external display under mouse")
        return nil
    }

    private func brightnessTarget(from candidateIDs: [CGDirectDisplayID]) -> ControlledDisplay? {
        for displayID in candidateIDs {
            guard let display = displays.first(where: { $0.id == displayID }) else {
                AppLogger.ui.debug("Brightness key candidate \(displayID) is not in controller list")
                continue
            }
            if display.isBuiltIn {
                continue
            }
            if display.supports(.brightness) {
                return display
            }
            AppLogger.ui.debug(
                "Brightness key candidate \(displayID) does not support brightness, reason: \(display.brightnessUnavailableReason ?? "unknown", privacy: .public)"
            )
        }
        return nil
    }

    private func primaryDisplayIDUnderMouse() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) else {
            return nil
        }
        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func displayIDsUnderMouse() -> [CGDirectDisplayID] {
        let mouseLocation = NSEvent.mouseLocation
        var candidates: [CGDirectDisplayID] = []

        func append(_ displayID: CGDirectDisplayID?) {
            guard let displayID, displayID != 0, !candidates.contains(displayID) else { return }
            candidates.append(displayID)
        }

        func appendMirroredDisplays(for displayID: CGDirectDisplayID) {
            let mirroredSource = CGDisplayMirrorsDisplay(displayID)
            if mirroredSource != 0 {
                append(mirroredSource)
            }

            for display in displays where CGDisplayMirrorsDisplay(display.id) == displayID {
                append(display.id)
            }
        }

        if let displayID = primaryDisplayIDUnderMouse() {
            append(displayID)
            appendMirroredDisplays(for: displayID)
        }

        for point in mousePointCandidates(appKitPoint: mouseLocation) {
            var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
            var displayCount: UInt32 = 0
            if CGGetDisplaysWithPoint(point, UInt32(displayIDs.count), &displayIDs, &displayCount) == .success, displayCount > 0 {
                for displayID in displayIDs.prefix(Int(displayCount)) {
                    append(displayID)
                    appendMirroredDisplays(for: displayID)
                }
            }

            for display in displays where CGDisplayBounds(display.id).contains(point) {
                append(display.id)
                appendMirroredDisplays(for: display.id)
            }
        }

        return candidates
    }

    private func mousePointCandidates(appKitPoint: CGPoint) -> [CGPoint] {
        var points = [appKitPoint]
        if let eventLocation = CGEvent(source: nil)?.location {
            points.append(eventLocation)
        }

        let frames = NSScreen.screens.map(\.frame)
        if let minY = frames.map(\.minY).min(),
           let maxY = frames.map(\.maxY).max() {
            points.append(CGPoint(x: appKitPoint.x, y: minY + maxY - appKitPoint.y))
        }

        var unique: [CGPoint] = []
        for point in points where !unique.contains(where: { abs($0.x - point.x) < 0.5 && abs($0.y - point.y) < 0.5 }) {
            unique.append(point)
        }
        return unique
    }

    func value(for control: DisplayControlKind, displayID: CGDirectDisplayID) -> Double {
        if let pendingValue = pendingValues[displayID]?[control] {
            return pendingValue
        }

        if let display = displays.first(where: { $0.id == displayID }) {
            return display.value(for: control)
        }

        return fallbackValues[displayID]?[control] ?? control.defaultValue
    }

    func setValueAsync(_ value: Double, for control: DisplayControlKind, displayID: CGDirectDisplayID) {
        setValue(
            value,
            for: control,
            displayID: displayID,
            mode: .coalesced,
            markUnsupportedOnFailure: true
        )
    }

    func setKeyboardBrightnessValue(_ value: Double, displayID: CGDirectDisplayID) {
        setValue(
            value,
            for: .brightness,
            displayID: displayID,
            mode: .ordered,
            markUnsupportedOnFailure: false
        )
    }

    private func setValue(
        _ value: Double,
        for control: DisplayControlKind,
        displayID: CGDirectDisplayID,
        mode: DisplayWriteMode,
        markUnsupportedOnFailure: Bool
    ) {
        let clampedValue = min(100, max(0, value))
        service.softwareDimmingEnabled = settings?.displaySoftwareDimmingEnabled ?? true
        guard let display = displays.first(where: { $0.id == displayID }) else {
            AppLogger.ui.error("Display not found for setValue: \(displayID)")
            return
        }
        guard display.supports(control) else {
            AppLogger.ui.error("Display \(displayID) does not support control: \(control.storageKey, privacy: .public)")
            return
        }

        let key = ControlKey(displayID: displayID, control: control)
        nextWriteSequence &+= 1
        let sequence = nextWriteSequence
        latestWriteSequences[key] = sequence
        pendingValues[displayID, default: [:]][control] = clampedValue
        worker.setValue(
            clampedValue,
            for: key,
            sequence: sequence,
            mode: mode,
            performWrite: { [service, display] value in
                service.setValue(value, for: key.control, display: display)
            }
        ) { [self] result in
            Task { @MainActor [self] in
                self.handleWriteResult(result, markUnsupportedOnFailure: markUnsupportedOnFailure)
            }
        }
    }

    private func seedFallbackValues(for display: ControlledDisplay) {
        fallbackValues[display.id] = [
            .brightness: display.brightness,
            .volume: display.volume,
            .contrast: display.contrast
        ]
    }

    private func mergedDisplayValues(for display: ControlledDisplay) -> ControlledDisplay {
        pruneExpiredRecentValues()
        var mergedDisplay = display
        for control in DisplayControlKind.allCases {
            let key = ControlKey(displayID: display.id, control: control)
            if let pendingValue = pendingValues[display.id]?[control] {
                mergedDisplay.setValue(pendingValue, for: control)
            } else if let recentValue = recentWrittenValues[key] {
                mergedDisplay.setValue(recentValue.value, for: control)
            }
        }
        return mergedDisplay
    }

    private func pruneExpiredRecentValues() {
        let now = Date()
        recentWrittenValues = recentWrittenValues.filter { now.timeIntervalSince($0.value.date) < 3 }
    }

    private func updateLocalValue(_ value: Double, for control: DisplayControlKind, displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
            return
        }
        guard DisplayValueChangePolicy.shouldPublish(
            current: displays[index].value(for: control),
            next: value
        ) else {
            return
        }

        displays[index].setValue(value, for: control)
    }

    private var activeControls: Set<DisplayControlKind> {
        guard let settings else {
            return Set(DisplayControlKind.allCases)
        }

        var controls: Set<DisplayControlKind> = []
        if settings.displayBrightnessControlEnabled || settings.brightnessKeyInterceptionEnabled {
            controls.insert(.brightness)
        }
        if settings.displayVolumeControlEnabled {
            controls.insert(.volume)
        }
        if settings.displayContrastControlEnabled {
            controls.insert(.contrast)
        }
        return controls
    }

    private func configureNativeBrightnessSync() {
        stopNativeBrightnessSync()
        guard DisplayNativeBrightnessSyncPolicy.shouldRun(
            panelVisible: isPanelVisible,
            moduleVisible: settings?.displayModuleVisible == true,
            brightnessControlEnabled: settings?.displayBrightnessControlEnabled == true,
            hasNativeBrightnessDisplay: displays.contains {
                $0.usesNativeBrightness && $0.supportsBrightness
            }
        ) else {
            return
        }

        nativeBrightnessSyncGeneration &+= 1
        let generation = nativeBrightnessSyncGeneration
        nativeBrightnessSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.syncNativeBrightness(generation: generation)
                do {
                    try await Task.sleep(
                        for: .milliseconds(
                            DisplayNativeBrightnessSyncPolicy.intervalMilliseconds
                        )
                    )
                } catch {
                    break
                }
            }
        }
    }

    private func stopNativeBrightnessSync() {
        nativeBrightnessSyncTask?.cancel()
        nativeBrightnessSyncTask = nil
        nativeBrightnessSyncGeneration &+= 1
        nativeBrightnessReadsInFlight.removeAll()
    }

    private func syncNativeBrightness(generation: Int) {
        guard generation == nativeBrightnessSyncGeneration else { return }

        let displayIDs = displays.compactMap { display -> CGDirectDisplayID? in
            guard display.usesNativeBrightness,
                  display.supportsBrightness,
                  !builtInBlackoutDisplayIDs.contains(display.id),
                  pendingValues[display.id]?[.brightness] == nil,
                  !nativeBrightnessReadsInFlight.contains(display.id)
            else {
                return nil
            }
            return display.id
        }

        for displayID in displayIDs {
            nativeBrightnessReadsInFlight.insert(displayID)
            worker.readNativeBrightness(
                displayID: displayID,
                performRead: { [service] in
                    service.nativeBrightness(displayID: displayID)
                }
            ) { [self] value in
                Task { @MainActor [self] in
                    guard generation == self.nativeBrightnessSyncGeneration else {
                        return
                    }
                    self.nativeBrightnessReadsInFlight.remove(displayID)
                    guard let value,
                          self.pendingValues[displayID]?[.brightness] == nil
                    else {
                        return
                    }

                    let key = ControlKey(displayID: displayID, control: .brightness)
                    self.recentWrittenValues[key] = nil
                    self.updateLocalValue(value, for: .brightness, displayID: displayID)
                    self.fallbackValues[displayID, default: [:]][.brightness] = value
                }
            }
        }
    }

    private func handleWriteResult(_ result: DisplayWriteResult, markUnsupportedOnFailure: Bool) {
        let isCurrentResult = latestWriteSequences[result.key] == result.sequence

        let latestConfirmedSequence = latestConfirmedWriteSequences[result.key] ?? 0
        if result.success, result.sequence >= latestConfirmedSequence {
            latestConfirmedWriteSequences[result.key] = result.sequence
            updateLocalValue(result.value, for: result.key.control, displayID: result.key.displayID)
            fallbackValues[result.key.displayID, default: [:]][result.key.control] = result.value
            recentWrittenValues[result.key] = RecentDisplayValue(value: result.value, date: Date())
            AppLogger.ui.debug(
                "Write succeeded for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public), current: \(isCurrentResult, privacy: .public)"
            )
        } else if result.success {
            AppLogger.ui.debug(
                "Ignored out-of-order confirmed write for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public)"
            )
        } else {
            AppLogger.ui.error("Write failed for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public)")
            if isCurrentResult, markUnsupportedOnFailure {
                markControlUnsupported(result.key.control, displayID: result.key.displayID)
            }
        }

        guard isCurrentResult else {
            return
        }

        latestWriteSequences[result.key] = nil
        pendingValues[result.key.displayID]?[result.key.control] = nil
        if pendingValues[result.key.displayID]?.isEmpty == true {
            pendingValues[result.key.displayID] = nil
        }
    }

    private func syncSoftwareDimming() {
        service.softwareDimmingEnabled = settings?.displaySoftwareDimmingEnabled ?? true
        guard service.softwareDimmingEnabled else {
            service.clearSoftwareDimming()
            return
        }
        service.syncSoftwareDimming(for: displays)
    }

    private func syncBuiltInBlackouts() {
        guard !builtInDisconnectRecoveryPending else { return }
        guard !topologyMaintenanceCoordinator.isRunning else { return }
        let externalDisplays = displays.filter { !$0.isBuiltIn }
        if externalDisplays.isEmpty,
           isBuiltInBlackoutDesired,
           builtInBlackoutDisplayIDs.isEmpty {
            let builtInDisplayIsOffline = service.hasOfflineCachedBuiltInDisplay()
            if BuiltInBlackoutIntentPolicy.shouldSuspendForMissingExternal(
                externalDisplayCount: 0,
                blackoutDesired: true,
                isolatedDisplayCount: 0,
                builtInDisplayIsOffline: builtInDisplayIsOffline
            ) {
                builtInBlackoutSuspendedForMissingExternal = true
                return
            }
        }
        guard !BuiltInDisplayRestorePolicy.shouldRestore(
            externalDisplayCount: externalDisplays.count,
            blackoutDesired: isBuiltInBlackoutDesired,
            isolatedDisplayCount: builtInBlackoutDisplayIDs.count
        ) else {
            guard !builtInBlackoutOperationPending else { return }
            AppLogger.ui.notice("No external display remains; restoring the built-in display")
            recoverBuiltInDisplayAfterExternalDisconnect(triggerDisplayID: 0)
            return
        }
        builtInBlackoutSuspendedForMissingExternal = false
        if isBuiltInBlackoutDesired {
            for display in displays where display.isBuiltIn {
                let needsIsolationMaintenance = !service.hasSettledBuiltInBlackout(
                    displayID: display.id
                )
                if (!builtInBlackoutDisplayIDs.contains(display.id) || needsIsolationMaintenance),
                   !builtInBlackoutOperationPending {
                    builtInBlackoutOperationPending = true
                    worker.setBuiltInBlackout(
                        true,
                        display: display,
                        displays: displays,
                        service: service
                    ) { [self] succeeded in
                        Task { @MainActor [self] in
                            self.builtInBlackoutOperationPending = false
                            self.builtInBlackoutActionFailed = !succeeded
                            guard BuiltInBlackoutMaintenancePolicy.action(
                                afterAttemptSucceeded: succeeded
                            ) == .recordIsolation else {
                                self.builtInBlackoutDisplayIDs.remove(display.id)
                                AppLogger.ui.error(
                                    "Automatic built-in display blackout failed; preserving user intent for retry"
                                )
                                self.topologyMaintenanceCoordinator
                                    .requestExternalConnectionMaintenance()
                                return
                            }
                            self.cachedBuiltInDisplay = display
                            self.builtInBlackoutSuspendedForMissingExternal = false
                            self.builtInBlackoutDisplayIDs.insert(display.id)
                            self.scheduleRefresh(delay: 0.15)
                        }
                    }
                }
            }
        }
    }

    private func recoverBuiltInDisplayAfterExternalDisconnect(
        triggerDisplayID: CGDirectDisplayID,
        forceRestore: Bool = false
    ) {
        guard forceRestore ? requiresPhysicalBuiltInRestore : needsBuiltInDisconnectRecovery else {
            return
        }
        guard !builtInDisconnectRecoveryPending,
              !builtInBlackoutOperationPending
        else {
            return
        }

        builtInDisconnectRecoveryPending = true
        if triggerDisplayID != 0 {
            AppLogger.ui.notice(
                "Display removal detected for ID \(triggerDisplayID); checking emergency built-in restore"
            )
        }

        worker.restoreBuiltInAfterExternalDisconnect(
            brightnessPercent: BuiltInDisplayRestorePolicy.disconnectedExternalBrightness,
            forceRestore: forceRestore,
            service: service
        ) { [self] result in
            Task { @MainActor [self] in
                self.builtInDisconnectRecoveryPending = false

                switch result {
                case .externalDisplayPresent:
                    if triggerDisplayID != 0 {
                        AppLogger.ui.debug("Skipped emergency built-in restore because an external display remains")
                    }
                    return
                case let .restored(displayID):
                    self.wakeRefreshGeneration &+= 1
                    self.builtInBlackoutActionFailed = false
                    self.fallbackValues[displayID, default: [:]][.brightness] =
                        BuiltInDisplayRestorePolicy.disconnectedExternalBrightness
                    if var cachedBuiltInDisplay = self.cachedBuiltInDisplay,
                       cachedBuiltInDisplay.id == displayID {
                        cachedBuiltInDisplay.brightness = BuiltInDisplayRestorePolicy.disconnectedExternalBrightness
                        cachedBuiltInDisplay.supportsBrightness = true
                        cachedBuiltInDisplay.brightnessUnavailableReason = nil
                        self.cachedBuiltInDisplay = cachedBuiltInDisplay
                    }
                    self.builtInBlackoutSuspendedForMissingExternal = self.isBuiltInBlackoutDesired
                    self.builtInBlackoutDisplayIDs.removeAll()
                    AppLogger.ui.notice(
                        "Restored built-in display ID \(displayID) at 35 percent after external disconnect"
                    )
                case let .brightnessPending(displayID):
                    self.wakeRefreshGeneration &+= 1
                    AppLogger.ui.debug(
                        "Built-in display ID \(displayID) is online but its 35 percent brightness is still pending"
                    )
                case .builtInDisplayUnavailable:
                    self.wakeRefreshGeneration &+= 1
                    if triggerDisplayID != 0 {
                        AppLogger.ui.error("Emergency built-in restore could not resolve the built-in display ID")
                    }
                }
                self.scheduleRefresh(delay: 0.12)
            }
        }
    }

    private func configureBuiltInDisconnectWatchdog() {
        guard needsBuiltInBlackoutMaintenance else {
            builtInDisconnectWatchdogGeneration &+= 1
            builtInDisconnectWatchdogTask?.cancel()
            builtInDisconnectWatchdogTask = nil
            return
        }
        guard builtInDisconnectWatchdogTask == nil else { return }

        builtInDisconnectWatchdogGeneration &+= 1
        let generation = builtInDisconnectWatchdogGeneration
        builtInDisconnectWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.builtInDisconnectWatchdogGeneration == generation,
                      self.needsBuiltInBlackoutMaintenance
                else {
                    break
                }
                guard BuiltInBlackoutMaintenancePolicy.shouldRunDisconnectRecovery(
                    isSystemSleeping: self.isSystemSleeping
                ) else {
                    try? await Task.sleep(
                        for: .seconds(BuiltInDisplayRestorePolicy.topologyWatchdogInterval)
                    )
                    continue
                }
                let externalServiceCount = await self.hardwareTopologyMonitor?.externalServiceCount()
                let builtInDisplayIsOffline = self.service.hasOfflineCachedBuiltInDisplay()
                let hasKnownExternalDisplay = externalServiceCount == nil
                    && self.service.hasUsableExternalDisplay()
                if !self.builtInDisconnectRecoveryPending,
                   DisplayHardwareDisconnectRecoveryPolicy.shouldAttemptWatchdogRecovery(
                       externalServiceCount: externalServiceCount,
                       builtInRestoreRequired: self.requiresPhysicalBuiltInRestore
                   ) {
                    let hardwareConfirmsNoExternal = DisplayHardwareDisconnectRecoveryPolicy.shouldForceRestore(
                        externalServiceCount: externalServiceCount,
                        isolatedDisplayCount: self.builtInBlackoutDisplayIDs.count,
                        builtInDisplayIsOffline: builtInDisplayIsOffline
                    )
                    self.recoverBuiltInDisplayAfterExternalDisconnect(
                        triggerDisplayID: 0,
                        forceRestore: hardwareConfirmsNoExternal
                    )
                } else if !self.builtInBlackoutOperationPending,
                          BuiltInBlackoutMaintenancePolicy.shouldReapplyUnexpectedRestore(
                              externalServiceCount: externalServiceCount,
                              hasKnownExternalDisplay: hasKnownExternalDisplay,
                              blackoutDesired: self.isBuiltInBlackoutDesired,
                              builtInDisplayIsOffline: builtInDisplayIsOffline
                          ) {
                    AppLogger.ui.notice(
                        "Built-in display unexpectedly restored while an external display remains; reapplying isolation"
                    )
                    self.topologyMaintenanceCoordinator.requestExternalConnectionMaintenance()
                }
                try? await Task.sleep(
                    for: .seconds(BuiltInDisplayRestorePolicy.topologyWatchdogInterval)
                )
            }
            if self?.builtInDisconnectWatchdogGeneration == generation {
                self?.builtInDisconnectWatchdogTask = nil
            }
        }
    }

    private var needsBuiltInDisconnectRecovery: Bool {
        !builtInBlackoutSuspendedForMissingExternal
            && needsBuiltInBlackoutMaintenance
    }

    private var requiresPhysicalBuiltInRestore: Bool {
        !builtInBlackoutDisplayIDs.isEmpty || service.hasOfflineCachedBuiltInDisplay()
    }

    private func markControlUnsupported(_ control: DisplayControlKind, displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
            return
        }

        displays[index].setSupported(false, for: control)
    }
}
