import AppKit
import Combine
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class DisplayControlController: ObservableObject {
    @Published private(set) var displays: [ControlledDisplay] = []
    @Published private var builtInBlackoutDisplayIDs: Set<CGDirectDisplayID> = []
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
    private var refreshWorkItem: DispatchWorkItem?
    private var wakeMaintenanceGeneration = 0
    private var displayCallbackRegistered = false
    private var isPanelVisible = false
    private var nativeBrightnessSyncTask: Task<Void, Never>?
    private var nativeBrightnessSyncGeneration = 0
    private var nativeBrightnessReadsInFlight: Set<CGDirectDisplayID> = []
    private var cachedBuiltInDisplay: ControlledDisplay?
    private var builtInTopologyOperationPending = false
    private var isBuiltInBlackoutDesired: Bool {
        get {
            defaults.bool(forKey: Self.builtInBlackoutPreferenceKey)
        }
        set {
            defaults.set(newValue, forKey: Self.builtInBlackoutPreferenceKey)
        }
    }
    var needsBuiltInBlackoutMaintenance: Bool {
        isBuiltInBlackoutDesired
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
                var mergedDisplays = detectedDisplays.map { self.mergedDisplayValues(for: $0) }
                if self.isBuiltInBlackoutDesired,
                   !mergedDisplays.contains(where: \.isBuiltIn),
                   var cachedBuiltInDisplay = self.cachedBuiltInDisplay
                    ?? self.service.isolatedBuiltInPlaceholder() {
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
            return
        }

        let shouldEnable = !builtInBlackoutDisplayIDs.contains(displayID)
        guard !builtInTopologyOperationPending else { return }
        builtInTopologyOperationPending = true
        worker.setBuiltInBlackout(
            shouldEnable,
            display: display,
            displays: displays,
            service: service
        ) { [weak self] succeeded in
            Task { @MainActor in
                guard let self else { return }
                self.builtInTopologyOperationPending = false
                guard succeeded else { return }
                if shouldEnable {
                    self.cachedBuiltInDisplay = display
                    self.isBuiltInBlackoutDesired = true
                    self.builtInBlackoutDisplayIDs.insert(displayID)
                } else {
                    self.isBuiltInBlackoutDesired = false
                    self.builtInBlackoutDisplayIDs.remove(displayID)
                }
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
                    controller.scheduleRefresh()
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
                    controller.scheduleWakeRefreshes()
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
                    controller.scheduleWakeRefreshes()
                }
            }
        }

        if powerEventBridge == nil {
            let bridge = DisplayPowerEventBridge { [weak self] event in
                self?.handlePowerEvent(event)
            }
            powerEventBridge = bridge
            bridge.start()
        }

        guard !displayCallbackRegistered else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        if CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, pointer) == .success {
            displayCallbackRegistered = true
        }
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
        stopNativeBrightnessSync()
    }

    func restoreBuiltInDisplayForTermination() {
        wakeMaintenanceGeneration &+= 1
        service.clearBuiltInBlackouts()
        builtInBlackoutDisplayIDs.removeAll()
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

    func scheduleWakeRefreshes(early: Bool = false) {
        AppLogger.ui.notice("Display wake detected; reapplying display control state")
        worker.invalidateDiscoveryCache()
        wakeMaintenanceGeneration &+= 1
        let generation = wakeMaintenanceGeneration
        let passes: [(delay: TimeInterval, fullRefresh: Bool)] = early
            ? [(0, false), (0.08, false), (0.25, false), (0.8, true)]
            : [(0, false), (0.2, false), (0.8, true), (2.0, true)]

        for pass in passes {
            DispatchQueue.main.asyncAfter(deadline: .now() + pass.delay) { [weak self] in
                Task { @MainActor in
                    self?.performWakeMaintenancePass(
                        generation: generation,
                        fullRefresh: pass.fullRefresh
                    )
                }
            }
        }
    }

    private func handlePowerEvent(_ event: DisplayPowerEvent) {
        guard isBuiltInBlackoutDesired else { return }
        switch event {
        case .willSleep:
            AppLogger.ui.notice("Preparing isolated built-in display for sleep")
            performWakeMaintenancePass(
                generation: wakeMaintenanceGeneration,
                fullRefresh: false
            )
        case .willPowerOn:
            scheduleWakeRefreshes(early: true)
        case .hasPoweredOn:
            scheduleWakeRefreshes()
        }
    }

    private func performWakeMaintenancePass(generation: Int, fullRefresh: Bool) {
        guard generation == wakeMaintenanceGeneration else {
            return
        }

        if isBuiltInBlackoutDesired, !builtInTopologyOperationPending {
            builtInTopologyOperationPending = true
            worker.reapplyBuiltInBlackouts(service: service) { [weak self] appliedDisplayIDs in
                Task { @MainActor in
                    guard let self else { return }
                    self.builtInTopologyOperationPending = false
                    if !appliedDisplayIDs.isEmpty {
                        self.builtInBlackoutDisplayIDs.formUnion(appliedDisplayIDs)
                    }
                }
            }
        }

        if fullRefresh {
            refreshAsync()
        } else if isBuiltInBlackoutDesired, !displays.isEmpty {
            syncBuiltInBlackouts()
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
        ) { [weak self] result in
            Task { @MainActor in
                self?.handleWriteResult(result, markUnsupportedOnFailure: markUnsupportedOnFailure)
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
            ) { [weak self] value in
                Task { @MainActor in
                    guard let self else { return }
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
        let externalDisplays = displays.filter { !$0.isBuiltIn }
        guard !externalDisplays.isEmpty else {
            guard isBuiltInBlackoutDesired || !builtInBlackoutDisplayIDs.isEmpty else { return }
            guard !builtInTopologyOperationPending else { return }
            builtInTopologyOperationPending = true
            builtInBlackoutDisplayIDs.removeAll()
            isBuiltInBlackoutDesired = false
            worker.clearBuiltInBlackouts(service: service) { [weak self] in
                Task { @MainActor in
                    self?.builtInTopologyOperationPending = false
                    self?.scheduleRefresh(delay: 0.2)
                }
            }
            return
        }
        if isBuiltInBlackoutDesired {
            for display in displays where display.isBuiltIn {
                if !builtInBlackoutDisplayIDs.contains(display.id),
                   !builtInTopologyOperationPending {
                    builtInTopologyOperationPending = true
                    worker.setBuiltInBlackout(
                        true,
                        display: display,
                        displays: displays,
                        service: service
                    ) { [weak self] succeeded in
                        Task { @MainActor in
                            guard let self else { return }
                            self.builtInTopologyOperationPending = false
                            guard succeeded else { return }
                            self.cachedBuiltInDisplay = display
                            self.builtInBlackoutDisplayIDs.insert(display.id)
                            self.scheduleRefresh(delay: 0.15)
                        }
                    }
                }
            }
        }
    }

    private func markControlUnsupported(_ control: DisplayControlKind, displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
            return
        }

        displays[index].setSupported(false, for: control)
    }
}

nonisolated enum DisplayWriteMode {
    case coalesced
    case ordered
}

nonisolated final class DisplayControlWorker: @unchecked Sendable {
    private struct PendingWrite {
        let value: Double
        let sequence: UInt64
        let performWrite: (Double) -> Bool
        let completion: (DisplayWriteResult) -> Void
    }

    private let stateQueue = DispatchQueue(label: "fanshu.display-control.state", qos: .userInitiated)
    private let hardwareQueue = DispatchQueue(
        label: "fanshu.display-control.hardware",
        qos: .userInitiated,
        attributes: .concurrent
    )
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
    private var discoveryGeneration: UInt64 = 0
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
        completion: @escaping ([ControlledDisplay]) -> Void
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
        performDiscovery: @escaping () -> [ControlledDisplay],
        completion: @escaping ([ControlledDisplay]) -> Void
    ) {
        stateQueue.async {
            let now = Date()
            if let cachedDiscovery = self.cachedDiscovery,
               cachedDiscovery.activeControls == activeControls,
               now.timeIntervalSince(cachedDiscovery.refreshedAt) < self.discoveryCacheInterval {
                completion(cachedDiscovery.displays)
                return
            }

            self.discoveryGeneration &+= 1
            let generation = self.discoveryGeneration
            self.discoveryQueue.async {
                let displays = performDiscovery()
                self.stateQueue.async {
                    guard generation == self.discoveryGeneration else {
                        return
                    }
                    self.cachedDiscovery = (displays, activeControls, now)
                    completion(displays)
                }
            }
        }
    }

    func readNativeBrightness(
        displayID: CGDirectDisplayID,
        performRead: @escaping () -> Double?,
        completion: @escaping (Double?) -> Void
    ) {
        stateQueue.async {
            let readQueue = self.writeQueue(for: displayID)
            readQueue.async {
                let value = self.hardwareQueue.sync {
                    performRead()
                }
                completion(value)
            }
        }
    }

    func setBuiltInBlackout(
        _ enabled: Bool,
        display: ControlledDisplay,
        displays: [ControlledDisplay],
        service: DisplayControlService,
        completion: @escaping (Bool) -> Void
    ) {
        topologyQueue.async {
            completion(service.setBuiltInBlackout(enabled, display: display, displays: displays))
        }
    }

    func reapplyBuiltInBlackouts(
        service: DisplayControlService,
        completion: @escaping (Set<CGDirectDisplayID>) -> Void
    ) {
        topologyQueue.async {
            completion(service.reapplyBuiltInBlackoutsToOnlineDisplays())
        }
    }

    func clearBuiltInBlackouts(
        service: DisplayControlService,
        completion: @escaping () -> Void
    ) {
        topologyQueue.async {
            service.clearBuiltInBlackouts()
            completion()
        }
    }

    func invalidateDiscoveryCache() {
        stateQueue.async {
            self.discoveryGeneration &+= 1
            self.cachedDiscovery = nil
        }
    }

    func setValue(
        _ value: Double,
        for key: ControlKey,
        sequence: UInt64,
        mode: DisplayWriteMode,
        performWrite: @escaping (Double) -> Bool,
        completion: @escaping (DisplayWriteResult) -> Void
    ) {
        stateQueue.async {
            switch mode {
            case .ordered:
                self.cancelPendingWrite(for: key)
                self.perform(
                    PendingWrite(
                        value: value,
                        sequence: sequence,
                        performWrite: performWrite,
                        completion: completion
                    ),
                    for: key
                )
            case .coalesced:
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

    private func perform(_ request: PendingWrite, for key: ControlKey) {
        let writeQueue = writeQueue(for: key.displayID)
        writeQueue.async {
            let success = self.hardwareQueue.sync {
                request.performWrite(request.value)
            }
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

nonisolated struct DisplayWriteResult {
    let key: ControlKey
    let value: Double
    let sequence: UInt64
    let success: Bool
}
