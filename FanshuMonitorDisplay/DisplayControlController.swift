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
    private var screenChangeObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    private var screensDidWakeObserver: NSObjectProtocol?
    private var refreshWorkItem: DispatchWorkItem?
    private var wakeMaintenanceGeneration = 0
    private var displayCallbackRegistered = false
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
        Task { @MainActor [service] in
            service.clearBuiltInBlackouts()
            service.clearSoftwareDimming()
        }
    }

    func refreshAsync() {
        worker.refresh(service: service) { detectedDisplays in
            DispatchQueue.main.async {
                AppLogger.ui.info("Display refresh completed, found \(detectedDisplays.count) displays")
                let mergedDisplays = detectedDisplays.map { self.mergedDisplayValues(for: $0) }
                self.displays = mergedDisplays
                for display in mergedDisplays {
                    self.seedFallbackValues(for: display)
                }
                self.syncBuiltInBlackouts()
                self.syncSoftwareDimming()
            }
        }
    }

    func refreshNow() {
        refreshWorkItem?.cancel()
        refreshAsync()
    }

    func refreshSynchronously() {
        refreshWorkItem?.cancel()
        let detectedDisplays = service.displays()
        AppLogger.ui.info("Synchronous display refresh completed, found \(detectedDisplays.count) displays")
        let mergedDisplays = detectedDisplays.map { mergedDisplayValues(for: $0) }
        displays = mergedDisplays
        for display in mergedDisplays {
            seedFallbackValues(for: display)
        }
        syncBuiltInBlackouts()
        syncSoftwareDimming()
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
        if service.setBuiltInBlackout(shouldEnable, display: display, displays: displays) {
            if shouldEnable {
                isBuiltInBlackoutDesired = true
                builtInBlackoutDisplayIDs.insert(displayID)
            } else {
                isBuiltInBlackoutDesired = false
                builtInBlackoutDisplayIDs.remove(displayID)
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

        guard !displayCallbackRegistered else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        if CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, pointer) == .success {
            displayCallbackRegistered = true
        }
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
    }

    func scheduleRefresh(delay: TimeInterval = 0.45) {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshAsync()
            }
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func scheduleWakeRefreshes() {
        AppLogger.ui.notice("Display wake detected; reapplying display control state")
        wakeMaintenanceGeneration &+= 1
        let generation = wakeMaintenanceGeneration
        let passes: [(delay: TimeInterval, fullRefresh: Bool)] = [
            (0.15, false),
            (0.8, true),
            (1.8, false),
            (3.2, true),
            (6.0, false),
            (10.0, true)
        ]

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

    private func performWakeMaintenancePass(generation: Int, fullRefresh: Bool) {
        guard generation == wakeMaintenanceGeneration, isBuiltInBlackoutDesired else {
            return
        }

        let appliedDisplayIDs = service.reapplyBuiltInBlackoutsToOnlineDisplays()
        if !appliedDisplayIDs.isEmpty {
            builtInBlackoutDisplayIDs.formUnion(appliedDisplayIDs)
        }

        if fullRefresh {
            refreshAsync()
        } else if !displays.isEmpty {
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
        setValue(value, for: control, displayID: displayID, markUnsupportedOnFailure: true)
    }

    func setKeyboardBrightnessValue(_ value: Double, displayID: CGDirectDisplayID) {
        setValue(value, for: .brightness, displayID: displayID, markUnsupportedOnFailure: false)
    }

    private func setValue(
        _ value: Double,
        for control: DisplayControlKind,
        displayID: CGDirectDisplayID,
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
        pendingValues[displayID, default: [:]][control] = clampedValue
        worker.setValue(clampedValue, for: key, display: display, service: service) { [weak self] result in
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

        displays[index].setValue(value, for: control)
    }

    private func handleWriteResult(_ result: DisplayWriteResult, markUnsupportedOnFailure: Bool) {
        let currentPendingValue = pendingValues[result.key.displayID]?[result.key.control]
        let isCurrentResult = currentPendingValue.map { abs($0 - result.value) < 0.001 } ?? false

        if result.success, isCurrentResult {
            updateLocalValue(result.value, for: result.key.control, displayID: result.key.displayID)
            fallbackValues[result.key.displayID, default: [:]][result.key.control] = result.value
            recentWrittenValues[result.key] = RecentDisplayValue(value: result.value, date: Date())
            AppLogger.ui.debug("Write succeeded for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public)")
        } else if result.success {
            AppLogger.ui.debug("Ignored stale write result for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public)")
        } else {
            AppLogger.ui.error("Write failed for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public)")
            if isCurrentResult, markUnsupportedOnFailure {
                markControlUnsupported(result.key.control, displayID: result.key.displayID)
            }
        }

        guard isCurrentResult else {
            return
        }

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
        let displayIDs = Set(displays.map(\.id))
        builtInBlackoutDisplayIDs = builtInBlackoutDisplayIDs.intersection(displayIDs)
        guard displays.contains(where: { !$0.isBuiltIn }) else {
            builtInBlackoutDisplayIDs.removeAll()
            service.clearBuiltInBlackouts()
            return
        }
        if isBuiltInBlackoutDesired {
            for display in displays where display.isBuiltIn {
                if service.setBuiltInBlackout(true, display: display, displays: displays) {
                    builtInBlackoutDisplayIDs.insert(display.id)
                }
            }
        }
        service.syncBuiltInBlackouts(keeping: builtInBlackoutDisplayIDs, displays: displays)
    }

    private func markControlUnsupported(_ control: DisplayControlKind, displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
            return
        }

        displays[index].setSupported(false, for: control)
    }
}

private final class DisplayControlWorker {
    private let queue = DispatchQueue(label: "fanshu.ddc", qos: .userInitiated)
    private var pendingWrites: [ControlKey: Double] = [:]
    private var debounceTimers: [ControlKey: DispatchWorkItem] = [:]
    private let debounceInterval: DispatchTimeInterval = .milliseconds(150)

    func refresh(service: DisplayControlService, completion: @escaping ([ControlledDisplay]) -> Void) {
        queue.async {
            completion(service.displays())
        }
    }

    func setValue(
        _ value: Double,
        for key: ControlKey,
        display: ControlledDisplay,
        service: DisplayControlService,
        completion: @escaping (DisplayWriteResult) -> Void
    ) {
        queue.async {
            self.pendingWrites[key] = value

            self.debounceTimers[key]?.cancel()
            let timer = DispatchWorkItem { [service, display, key, completion] in
                guard let latestValue = self.pendingWrites.removeValue(forKey: key) else {
                    return
                }
                self.debounceTimers.removeValue(forKey: key)

                let success = service.setValue(latestValue, for: key.control, display: display)
                completion(DisplayWriteResult(key: key, value: latestValue, success: success))
            }
            self.debounceTimers[key] = timer
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: timer)
        }
    }
}

private nonisolated struct DisplayWriteResult {
    let key: ControlKey
    let value: Double
    let success: Bool
}
