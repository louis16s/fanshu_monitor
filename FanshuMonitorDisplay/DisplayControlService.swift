import AppKit
import CoreGraphics
import Darwin
import Foundation
import OSLog

nonisolated final class DisplayControlService: @unchecked Sendable {
    private static let cachedBuiltInDisplayIDKey = "displayControl.cachedBuiltInDisplayID"
    private static let cachedBuiltInBrightnessKey = "displayControl.cachedBuiltInBrightness"
    private static let builtInRecoverySnapshotKey = "displayControl.builtInRecoverySnapshot.v1"
    private let displayServices = DisplayServicesBridge()
    private let ddc = DisplayDDCBridge()
    private let defaults: UserDefaults
    private let softwareDimming = DisplaySoftwareDimmingService()
    private let builtInBlackout = BuiltInDisplayBlackoutService()
    private let displayClassifier = DisplayClassifier()
    private let ddcRangeStore: DisplayDDCRangeStore
    private let configurationLock = NSLock()
    private var storedSoftwareDimmingEnabled = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ddcRangeStore = DisplayDDCRangeStore(defaults: defaults)
    }

    var softwareDimmingEnabled: Bool {
        get { configurationLock.withLock { storedSoftwareDimmingEnabled } }
        set { configurationLock.withLock { storedSoftwareDimmingEnabled = newValue } }
    }

    func displays(reading activeControls: Set<DisplayControlKind> = Set(DisplayControlKind.allCases)) -> [ControlledDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            AppLogger.ui.error("CGGetOnlineDisplayList failed")
            return []
        }

        let displayIDs = Array(ids.prefix(Int(count)))
        AppLogger.ui.info("Detected \(displayIDs.count) online displays")
        if !activeControls.isEmpty {
            ddc.refresh(displayIDs: displayIDs)
        }

        return displayIDs.map { id in
            let displayKind = displayClassifier.classify(displayID: id)
            let isBuiltIn = displayKind == .builtIn
            let usesNativeBrightness = displayKind == .builtIn || displayKind == .appleNative
            let usesDDC = displayKind == .externalDDC
            let name = displayName(for: id, isBuiltIn: isBuiltIn)
            let storageID = displayStorageID(for: id, name: name, isBuiltIn: isBuiltIn)
            if usesDDC, let storedRange = ddcRangeStore.range(displayStorageID: storageID) {
                ddc.setValueRange(storedRange, for: .brightness, displayID: id)
            }
            let appleBrightness = usesNativeBrightness && activeControls.contains(.brightness)
                ? displayServices.getBrightness(displayID: id)
                : nil
            if isBuiltIn {
                cacheBuiltInDisplay(displayID: id, brightness: appleBrightness)
            }
            let hasDDCService = usesDDC && ddc.hasService(for: id)
            let brightnessTemporarilyDisabled = usesDDC && ddc.isTemporarilyDisabled(.brightness, displayID: id)
            let volumeTemporarilyDisabled = usesDDC && ddc.isTemporarilyDisabled(.volume, displayID: id)
            let contrastTemporarilyDisabled = usesDDC && ddc.isTemporarilyDisabled(.contrast, displayID: id)
            let ddcBrightness = usesDDC && activeControls.contains(.brightness)
                ? ddc.read(.brightness, displayID: id)
                : nil
            let ddcVolume = usesDDC && activeControls.contains(.volume)
                ? ddc.read(.volume, displayID: id)
                : nil
            let ddcContrast = usesDDC && activeControls.contains(.contrast)
                ? ddc.read(.contrast, displayID: id)
                : nil
            let storedBrightness = storedValue(for: .brightness, displayStorageID: storageID)
            let storedVolume = storedValue(for: .volume, displayStorageID: storageID)
            let storedContrast = storedValue(for: .contrast, displayStorageID: storageID)
            let hasVerifiedDDCBrightness = usesDDC && ddc.hasVerifiedControl(.brightness, displayID: id)
            let supportsBrightness = Self.supportsBrightness(
                displayKind: displayKind,
                nativeBrightnessAvailable: appleBrightness != nil,
                ddcBrightnessAvailable: ddcBrightness != nil,
                ddcBrightnessPreviouslyVerified: hasVerifiedDDCBrightness,
                isTemporarilyDisabled: brightnessTemporarilyDisabled
            )
            let supportsVolume = usesDDC && !volumeTemporarilyDisabled && (ddcVolume != nil || storedVolume != nil)
            let supportsContrast = usesDDC && !contrastTemporarilyDisabled && (ddcContrast != nil || storedContrast != nil)
            if usesDDC,
               ddcBrightness != nil,
               let learnedRange = ddc.valueRange(for: .brightness, displayID: id) {
                ddcRangeStore.save(learnedRange, displayStorageID: storageID)
            }
            let restoredQuantizationOpacity: Double
            if usesDDC, let storedBrightness {
                let mappedHardware = softwareDimming.hardwareBrightness(forUserBrightness: storedBrightness)
                restoredQuantizationOpacity = ddc.brightnessWritePlan(
                    for: mappedHardware,
                    displayID: id
                ).overlayOpacity
            } else {
                restoredQuantizationOpacity = 0
            }

            return ControlledDisplay(
                id: id,
                storageID: storageID,
                name: name,
                kind: displayKind,
                isBuiltIn: isBuiltIn,
                usesNativeBrightness: usesNativeBrightness,
                supportsBrightness: supportsBrightness,
                supportsVolume: supportsVolume,
                supportsContrast: supportsContrast,
                brightness: appleBrightness.map { Double($0 * 100) }
                    ?? softwareDimming.userBrightness(
                        for: id,
                        storedUserBrightness: storedBrightness,
                        hardwareBrightness: ddcBrightness,
                        restoredQuantizationOpacity: restoredQuantizationOpacity
                    )
                    ?? storedBrightness
                    ?? DisplayControlKind.brightness.defaultValue,
                volume: ddcVolume
                    ?? storedVolume
                    ?? DisplayControlKind.volume.defaultValue,
                contrast: ddcContrast
                    ?? storedContrast
                    ?? DisplayControlKind.contrast.defaultValue,
                brightnessUnavailableReason: supportsBrightness ? nil : unavailableReason(
                    for: .brightness,
                    displayKind: displayKind,
                    hasDDCService: hasDDCService,
                    isTemporarilyDisabled: brightnessTemporarilyDisabled
                ),
                volumeUnavailableReason: supportsVolume ? nil : unavailableReason(
                    for: .volume,
                    displayKind: displayKind,
                    hasDDCService: hasDDCService,
                    isTemporarilyDisabled: volumeTemporarilyDisabled
                ),
                contrastUnavailableReason: supportsContrast ? nil : unavailableReason(
                    for: .contrast,
                    displayKind: displayKind,
                    hasDDCService: hasDDCService,
                    isTemporarilyDisabled: contrastTemporarilyDisabled
                ),
                capabilities: nil
            )
        }
    }

    func setValue(_ value: Double, for control: DisplayControlKind, display: ControlledDisplay) -> Bool {
        guard display.supports(control) else {
            return false
        }

        if display.usesNativeBrightness {
            switch control {
            case .brightness:
                return displayServices.setBrightness(displayID: display.id, value: Float(value / 100))
            case .volume, .contrast:
                return false
            }
        }

        var writeValue = value
        if control == .brightness {
            if softwareDimmingEnabled {
                writeValue = softwareDimming.hardwareBrightness(forUserBrightness: value)
            } else {
                softwareDimming.clear(displayID: display.id)
            }
        }

        let outcome = ddc.write(writeValue, for: control, displayID: display.id)
        if outcome.success {
            if control == .brightness, softwareDimmingEnabled {
                softwareDimming.setUserBrightness(
                    value,
                    for: display.id,
                    additionalOverlayOpacity: outcome.quantizationOverlayOpacity
                )
            }
            if control == .brightness,
               let range = ddc.valueRange(for: .brightness, displayID: display.id) {
                ddcRangeStore.save(range, displayStorageID: display.storageID)
            }
            saveStoredValue(value, for: control, displayStorageID: display.storageID)
        }
        return outcome.success
    }

    func nativeBrightness(displayID: CGDirectDisplayID) -> Double? {
        displayServices.getBrightness(displayID: displayID).map { Double($0 * 100) }
    }

    nonisolated static func supportsBrightness(
        displayKind: DisplayKind,
        nativeBrightnessAvailable: Bool,
        ddcBrightnessAvailable: Bool,
        ddcBrightnessPreviouslyVerified: Bool,
        isTemporarilyDisabled: Bool
    ) -> Bool {
        switch displayKind {
        case .builtIn, .appleNative:
            return nativeBrightnessAvailable
        case .externalDDC:
            return !isTemporarilyDisabled && (ddcBrightnessAvailable || ddcBrightnessPreviouslyVerified)
        case .virtual, .dummy, .unsupported:
            return false
        }
    }

    func syncSoftwareDimming(for displays: [ControlledDisplay]) {
        softwareDimming.sync(with: displays)
    }

    func clearSoftwareDimming() {
        softwareDimming.clearAll()
    }

    func setBuiltInBlackout(_ enabled: Bool, display: ControlledDisplay, displays: [ControlledDisplay]) -> Bool {
        guard display.isBuiltIn else {
            return false
        }

        if enabled {
            guard let mirrorTarget = displays.first(where: { !$0.isBuiltIn }) else {
                return false
            }
            let previousBrightness = displayServices.getBrightness(displayID: display.id)
                ?? Float(display.brightness / 100)
            cacheBuiltInDisplay(displayID: display.id, brightness: previousBrightness)
            let didMirror = builtInBlackout.setEnabled(
                true,
                displayID: display.id,
                mirrorTargetID: mirrorTarget.id,
                previousBrightness: previousBrightness
            )
            guard didMirror else {
                return false
            }
            if builtInBlackout.isUsingMirrorFallback(displayID: display.id) {
                _ = displayServices.setBrightness(displayID: display.id, value: 0)
            }
            return didMirror
        }

        guard builtInBlackout.setEnabled(false, displayID: display.id, mirrorTargetID: nil, previousBrightness: nil) else {
            AppLogger.ui.error("Failed to restore built-in display ID \(display.id)")
            return false
        }
        let cachedBrightness = defaults.object(forKey: Self.cachedBuiltInBrightnessKey) as? Double
        let restoredBrightness = builtInBlackout.restoreBrightness(for: display.id)
            ?? cachedBrightness.map(Float.init)
            ?? Float(display.brightness / 100)
        _ = displayServices.setBrightness(displayID: display.id, value: restoredBrightness)
        return true
    }

    func reapplyBuiltInBlackoutsToOnlineDisplays() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            AppLogger.ui.error("CGGetOnlineDisplayList failed while reapplying built-in blackout")
            return []
        }

        let displayIDs = Array(ids.prefix(Int(count)))
        guard let mirrorTargetID = displayIDs.first(where: { CGDisplayIsBuiltin($0) == 0 }) else {
            return []
        }

        var appliedDisplayIDs: Set<CGDirectDisplayID> = []
        for displayID in displayIDs where CGDisplayIsBuiltin(displayID) == 1 {
            let previousBrightness = displayServices.getBrightness(displayID: displayID)
            cacheBuiltInDisplay(displayID: displayID, brightness: previousBrightness)
            if builtInBlackout.setEnabled(
                true,
                displayID: displayID,
                mirrorTargetID: mirrorTargetID,
                previousBrightness: previousBrightness
            ) {
                if builtInBlackout.isUsingMirrorFallback(displayID: displayID) {
                    _ = displayServices.setBrightness(displayID: displayID, value: 0)
                }
                appliedDisplayIDs.insert(displayID)
            }
        }
        return appliedDisplayIDs
    }

    func hasSettledBuiltInBlackout(displayID: CGDirectDisplayID) -> Bool {
        builtInBlackout.hasSettledIsolation(displayID: displayID)
    }

    @discardableResult
    func clearBuiltInBlackouts(restoredBrightnessOverride: Float? = nil) -> CGDirectDisplayID? {
        let brightnessByDisplayID = builtInBlackout.clearAll()
        if restoredBrightnessOverride == nil {
            for (displayID, brightness) in brightnessByDisplayID {
                _ = displayServices.setBrightness(displayID: displayID, value: brightness)
            }
        }

        guard let cachedDisplayID = cachedOrDiscoverableBuiltInDisplayID() else { return nil }
        if !builtInBlackout.isRestored(displayID: cachedDisplayID) {
            let restored = builtInBlackout.setEnabled(
                false,
                displayID: cachedDisplayID,
                mirrorTargetID: nil,
                previousBrightness: nil
            )
            if restored {
                AppLogger.ui.notice("Restored cached built-in display ID \(cachedDisplayID)")
            } else {
                AppLogger.ui.error("Failed to restore cached built-in display ID \(cachedDisplayID)")
            }
        }

        guard builtInBlackout.isRestored(displayID: cachedDisplayID) else {
            return nil
        }

        if let restoredBrightnessOverride {
            cacheBuiltInDisplay(
                displayID: cachedDisplayID,
                brightness: restoredBrightnessOverride
            )
        } else if let cachedBrightness = defaults.object(forKey: Self.cachedBuiltInBrightnessKey) as? Double {
            _ = displayServices.setBrightness(
                displayID: cachedDisplayID,
                value: Float(cachedBrightness)
            )
        }
        return cachedDisplayID
    }

    func hasUsableExternalDisplay() -> Bool {
        if let displayIDs = activeDisplayIDs() {
            return displayIDs.contains { CGDisplayIsBuiltin($0) == 0 }
        }

        // The active list can briefly fail while WindowServer commits a
        // zero-display topology. The online list is useful only as a fallback;
        // treating an online-but-inactive ghost as usable would block recovery.
        guard let displayIDs = onlineDisplayIDs() else {
            AppLogger.ui.error("Unable to query display topology during emergency built-in restore")
            return false
        }
        return displayIDs.contains {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) == 1
        }
    }

    func hasOfflineCachedBuiltInDisplay() -> Bool {
        guard let displayID = cachedOrDiscoverableBuiltInDisplayID(),
              CGDisplayIsBuiltin(displayID) == 1
        else {
            return false
        }
        return CGDisplayIsOnline(displayID) != 1 || CGDisplayIsActive(displayID) == 0
    }

    func reconcileRestoredBuiltInDisplays(
        candidates: Set<CGDirectDisplayID>
    ) -> Set<CGDirectDisplayID> {
        builtInBlackout.removeRestoredStates(candidates: candidates)
    }

    func setBuiltInBrightness(_ brightness: Float, displayID: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsOnline(displayID) == 1,
              CGDisplayIsBuiltin(displayID) == 1
        else {
            return false
        }
        let clamped = min(1, max(0, brightness))
        let succeeded = displayServices.setBrightness(displayID: displayID, value: clamped)
        if succeeded {
            cacheBuiltInDisplay(displayID: displayID, brightness: clamped)
        }
        return succeeded
    }

    func isolatedBuiltInPlaceholder() -> ControlledDisplay? {
        guard let displayID = cachedOrDiscoverableBuiltInDisplayID() else {
            return nil
        }
        return ControlledDisplay(
            id: displayID,
            storageID: "built-in-\(displayID)",
            name: "视网膜显示器",
            kind: .builtIn,
            isBuiltIn: true,
            usesNativeBrightness: true,
            supportsBrightness: false,
            supportsVolume: false,
            supportsContrast: false,
            brightness: 0,
            volume: DisplayControlKind.volume.defaultValue,
            contrast: DisplayControlKind.contrast.defaultValue,
            brightnessUnavailableReason: "已关闭",
            volumeUnavailableReason: "内建显示器不支持此控制项",
            contrastUnavailableReason: "内建显示器不支持此控制项",
            capabilities: nil
        )
    }

    private func cachedOrDiscoverableBuiltInDisplayID() -> CGDirectDisplayID? {
        let allDisplayIDs = builtInBlackout.allDisplayIDs()
        if let snapshot = builtInRecoverySnapshot(),
           let rediscoveredID = allDisplayIDs.first(where: {
               CGDisplayIsBuiltin($0) == 1 && snapshot.identity.matches(displayID: $0)
           }) {
            cacheBuiltInDisplay(
                displayID: rediscoveredID,
                brightness: Float(snapshot.brightness)
            )
            return rediscoveredID
        }

        if let displayID = allDisplayIDs.first(where: { CGDisplayIsBuiltin($0) == 1 }) {
            cacheBuiltInDisplay(displayID: displayID, brightness: nil)
            AppLogger.ui.info("Recovered isolated built-in display identity: \(displayID)")
            return displayID
        }

        if let cachedDisplayID = cachedBuiltInDisplayID(),
           CGDisplayIsBuiltin(cachedDisplayID) == 1 {
            return cachedDisplayID
        }

        // The private all-display list is not guaranteed to exist on every macOS
        // release. A bounded runtime-ID scan is the final recovery fallback.
        if let displayID = Self.firstBuiltInDisplayID(
            in: (1...256).map(CGDirectDisplayID.init),
            isBuiltIn: { CGDisplayIsBuiltin($0) == 1 }
        ) {
            cacheBuiltInDisplay(displayID: displayID, brightness: nil)
            return displayID
        }
        return nil
    }

    private func cacheBuiltInDisplay(displayID: CGDirectDisplayID, brightness: Float?) {
        guard CGDisplayIsBuiltin(displayID) == 1 else { return }
        let resolvedBrightness = brightness.map(Double.init)
            ?? builtInRecoverySnapshot()?.brightness
            ?? (defaults.object(forKey: Self.cachedBuiltInBrightnessKey) as? Double)
            ?? 0.35
        let snapshot = BuiltInDisplayRecoverySnapshot(
            displayID: displayID,
            brightness: resolvedBrightness
        )
        if defaults.object(forKey: Self.cachedBuiltInDisplayIDKey) as? Int != Int(displayID) {
            defaults.set(Int(displayID), forKey: Self.cachedBuiltInDisplayIDKey)
        }
        let cachedBrightness = defaults.object(forKey: Self.cachedBuiltInBrightnessKey) as? Double
        if cachedBrightness == nil || abs((cachedBrightness ?? 0) - snapshot.brightness) > 0.001 {
            defaults.set(snapshot.brightness, forKey: Self.cachedBuiltInBrightnessKey)
        }

        guard let encoded = try? JSONEncoder().encode(snapshot),
              defaults.data(forKey: Self.builtInRecoverySnapshotKey) != encoded
        else {
            return
        }
        defaults.set(encoded, forKey: Self.builtInRecoverySnapshotKey)
    }

    private func builtInRecoverySnapshot() -> BuiltInDisplayRecoverySnapshot? {
        guard let data = defaults.data(forKey: Self.builtInRecoverySnapshotKey),
              let snapshot = try? JSONDecoder().decode(BuiltInDisplayRecoverySnapshot.self, from: data),
              snapshot.schemaVersion == BuiltInDisplayRecoverySnapshot.schemaVersion
        else {
            return nil
        }
        return snapshot
    }

    private func cachedBuiltInDisplayID() -> CGDirectDisplayID? {
        guard let storedID = defaults.object(forKey: Self.cachedBuiltInDisplayIDKey) as? Int else {
            return nil
        }
        return CGDirectDisplayID(storedID)
    }

    private func onlineDisplayIDs() -> Set<CGDirectDisplayID>? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            return nil
        }
        return Set(ids.prefix(Int(count)))
    }

    private func activeDisplayIDs() -> Set<CGDirectDisplayID>? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            return nil
        }
        return Set(ids.prefix(Int(count)))
    }

    nonisolated static func firstBuiltInDisplayID(
        in candidates: [CGDirectDisplayID],
        isBuiltIn: (CGDirectDisplayID) -> Bool
    ) -> CGDirectDisplayID? {
        candidates.first(where: isBuiltIn)
    }

    private func displayName(for id: CGDirectDisplayID, isBuiltIn: Bool) -> String {
        if isBuiltIn {
            return "视网膜显示器"
        }

        if let info = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as? [String: Any],
           let localizedNames = info["DisplayProductName"] as? [String: String] {
            let name = localizedNames[Locale.current.identifier]
                ?? localizedNames["zh_CN"]
                ?? localizedNames["en_US"]
                ?? localizedNames.first?.value
            if let name {
                return name
            }
        }

        let model = CGDisplayModelNumber(id)
        return model == 0 ? "外接显示器" : "外接显示器 \(model)"
    }

    private func displayStorageID(for id: CGDirectDisplayID, name: String, isBuiltIn: Bool) -> String {
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        let role = isBuiltIn ? "builtIn" : "external"
        let sanitizedName = name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "\(role).\(sanitizedName).\(vendor).\(model).\(serial)"
    }

    private func storedValue(for control: DisplayControlKind, displayStorageID: String) -> Double? {
        let key = storedValueKey(for: control, displayStorageID: displayStorageID)
        guard defaults.object(forKey: key) != nil else {
            return nil
        }
        return min(100, max(0, defaults.double(forKey: key)))
    }

    private func saveStoredValue(_ value: Double, for control: DisplayControlKind, displayStorageID: String) {
        defaults.set(min(100, max(0, value)), forKey: storedValueKey(for: control, displayStorageID: displayStorageID))
    }

    private func storedValueKey(for control: DisplayControlKind, displayStorageID: String) -> String {
        "displayControl.value.\(displayStorageID).\(control.storageKey)"
    }

    private func unavailableReason(
        for control: DisplayControlKind,
        displayKind: DisplayKind,
        hasDDCService: Bool,
        isTemporarilyDisabled: Bool
    ) -> String {
        if isTemporarilyDisabled {
            return "DDC 暂时不可用，稍后自动重试"
        }

        switch displayKind {
        case .builtIn:
            switch control {
            case .brightness:
                return "系统亮度服务不可用"
            case .volume:
                return "内建屏不支持 DDC 音量"
            case .contrast:
                return "内建屏不支持 DDC 对比度"
            }
        case .appleNative:
            switch control {
            case .brightness:
                return "Apple 原生亮度服务不可用"
            case .volume:
                return "Apple 原生亮度显示器不支持 DDC 音量"
            case .contrast:
                return "Apple 原生亮度显示器不支持 DDC 对比度"
            }
        case .virtual:
            return "虚拟显示器不支持 DDC 控制"
        case .dummy:
            return "Dummy 显示器不支持 DDC 控制"
        case .externalDDC:
            guard hasDDCService else {
                return "未匹配到 DDC/CI 服务"
            }
            switch control {
            case .brightness:
                return "显示器未响应亮度 VCP"
            case .volume:
                return "显示器未响应音量 VCP"
            case .contrast:
                return "显示器未响应对比度 VCP"
            }
        case .unsupported:
            return "显示器类型暂不支持"
        }
    }
}

nonisolated struct DisplayDDCRangeStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func range(displayStorageID: String) -> DDCValueRange? {
        guard let dictionary = defaults.dictionary(forKey: key(displayStorageID: displayStorageID)),
              let minimum = dictionary["min"] as? NSNumber,
              let maximum = dictionary["max"] as? NSNumber
        else {
            return nil
        }
        let minValue = UInt16(clamping: minimum.intValue)
        let maxValue = UInt16(clamping: maximum.intValue)
        guard maxValue > minValue else {
            return nil
        }
        return DDCValueRange(min: minValue, max: maxValue)
    }

    func save(_ range: DDCValueRange, displayStorageID: String) {
        defaults.set(
            ["min": Int(range.min), "max": Int(range.max)],
            forKey: key(displayStorageID: displayStorageID)
        )
    }

    private func key(displayStorageID: String) -> String {
        "displayControl.ddcRange.\(displayStorageID).brightness"
    }
}

nonisolated enum DisplayDimmingCalibration {
    static let hardwareZeroUserBrightness: Double = 15
    static let maximumOverlayOpacity: Double = 0.70

    static func hardwareBrightness(forUserBrightness userBrightness: Double) -> Double {
        let clamped = min(100, max(0, userBrightness))
        guard clamped > hardwareZeroUserBrightness else { return 0 }
        return min(
            100,
            max(0, (clamped - hardwareZeroUserBrightness) / (100 - hardwareZeroUserBrightness) * 100)
        )
    }

    static func overlayOpacity(forUserBrightness userBrightness: Double) -> Double {
        let clamped = min(hardwareZeroUserBrightness, max(0, userBrightness))
        return (1 - clamped / hardwareZeroUserBrightness) * maximumOverlayOpacity
    }
}

enum DisplaySoftwareDimmingWindowPolicy {
    // A later-created screen saver window can cover windows at the same level.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
}

nonisolated private final class DisplaySoftwareDimmingService: @unchecked Sendable {
    private let dimmingThreshold: Double = DisplayDimmingCalibration.hardwareZeroUserBrightness
    private let maximumOverlayOpacity: Double = DisplayDimmingCalibration.maximumOverlayOpacity
    private let lock = NSLock()
    private var requestedBrightness: [CGDirectDisplayID: Double] = [:]
    private var quantizationOverlayOpacity: [CGDirectDisplayID: Double] = [:]
    @MainActor private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]

    func userBrightness(
        for displayID: CGDirectDisplayID,
        storedUserBrightness: Double?,
        hardwareBrightness: Double?,
        restoredQuantizationOpacity: Double
    ) -> Double? {
        if let cached = cachedBrightness(for: displayID) {
            return cached
        }

        if let storedUserBrightness {
            setUserBrightness(
                storedUserBrightness,
                for: displayID,
                additionalOverlayOpacity: restoredQuantizationOpacity
            )
            return storedUserBrightness
        }

        guard let hardwareBrightness else { return nil }
        return min(100, max(0, dimmingThreshold + (hardwareBrightness / 100) * (100 - dimmingThreshold)))
    }

    func hardwareBrightness(forUserBrightness userBrightness: Double) -> Double {
        DisplayDimmingCalibration.hardwareBrightness(forUserBrightness: userBrightness)
    }

    func setUserBrightness(
        _ userBrightness: Double,
        for displayID: CGDirectDisplayID,
        additionalOverlayOpacity: Double = 0
    ) {
        let clamped = min(100, max(0, userBrightness))
        let clampedAdditionalOpacity = min(1, max(0, additionalOverlayOpacity))
        lock.lock()
        requestedBrightness[displayID] = clamped
        quantizationOverlayOpacity[displayID] = clampedAdditionalOpacity
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.apply(
                userBrightness: clamped,
                additionalOverlayOpacity: clampedAdditionalOpacity,
                for: displayID
            )
        }
    }

    func sync(with displays: [ControlledDisplay]) {
        let displayIDs = Set(displays.map(\.id))
        let brightnessByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.brightness) })

        lock.lock()
        requestedBrightness = requestedBrightness.filter { displayIDs.contains($0.key) }
        quantizationOverlayOpacity = quantizationOverlayOpacity.filter { displayIDs.contains($0.key) }
        for (displayID, brightness) in brightnessByID where CGDisplayIsBuiltin(displayID) == 0 {
            requestedBrightness[displayID] = brightness
        }
        let values = requestedBrightness
        let additionalOpacities = quantizationOverlayOpacity
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for (displayID, brightness) in values {
                self.apply(
                    userBrightness: brightness,
                    additionalOverlayOpacity: additionalOpacities[displayID] ?? 0,
                    for: displayID
                )
            }
            self.removeMissingWindows(keeping: displayIDs)
        }
    }

    func clear(displayID: CGDirectDisplayID) {
        lock.lock()
        requestedBrightness[displayID] = nil
        quantizationOverlayOpacity[displayID] = nil
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.removeWindow(for: displayID)
        }
    }

    func clearAll() {
        lock.lock()
        requestedBrightness.removeAll()
        quantizationOverlayOpacity.removeAll()
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for displayID in Array(self.overlayWindows.keys) {
                self.removeWindow(for: displayID)
            }
        }
    }

    private func cachedBrightness(for displayID: CGDirectDisplayID) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return requestedBrightness[displayID]
    }

    @MainActor
    private func apply(
        userBrightness: Double,
        additionalOverlayOpacity: Double,
        for displayID: CGDirectDisplayID
    ) {
        guard CGDisplayIsBuiltin(displayID) == 0 else {
            removeWindow(for: displayID)
            return
        }

        let baseOpacity = overlayOpacity(for: userBrightness)
        let opacity = 1 - (1 - baseOpacity) * (1 - additionalOverlayOpacity)
        guard opacity > 0.001 else {
            removeWindow(for: displayID)
            return
        }

        guard let screen = screen(for: displayID) else {
            removeWindow(for: displayID)
            return
        }

        let window = overlayWindows[displayID] ?? makeWindow(for: screen)
        overlayWindows[displayID] = window
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
        window.alphaValue = opacity
        window.orderFrontRegardless()
    }

    private func overlayOpacity(for userBrightness: Double) -> Double {
        DisplayDimmingCalibration.overlayOpacity(forUserBrightness: userBrightness)
    }

    @MainActor
    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = DisplaySoftwareDimmingWindowPolicy.level
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = NSView(frame: screen.frame)
        return window
    }

    @MainActor
    private func removeMissingWindows(keeping displayIDs: Set<CGDirectDisplayID>) {
        for displayID in Array(overlayWindows.keys) where !displayIDs.contains(displayID) {
            removeWindow(for: displayID)
        }
    }

    @MainActor
    private func removeWindow(for displayID: CGDirectDisplayID) {
        guard let window = overlayWindows[displayID] else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    @MainActor
    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

nonisolated private final class BuiltInDisplayBlackoutService: @unchecked Sendable {
    private enum IsolationMode {
        case disconnected
        case mirrored
    }

    private struct IsolationState {
        var previousBrightness: Float?
        var mode: IsolationMode
        var isPersistent: Bool
    }

    private typealias ConfigureDisplayEnabledFunction = @convention(c) (
        CGDisplayConfigRef?,
        CGDirectDisplayID,
        Bool
    ) -> CGError

    private typealias GetDisplayListFunction = @convention(c) (
        UInt32,
        UnsafeMutablePointer<CGDirectDisplayID>?,
        UnsafeMutablePointer<UInt32>?
    ) -> CGError

    private let frameworkHandles: [UnsafeMutableRawPointer]
    private let configureDisplayEnabled: ConfigureDisplayEnabledFunction?
    private let getDisplayList: GetDisplayListFunction?
    private let stateLock = NSLock()
    private var states: [CGDirectDisplayID: IsolationState] = [:]

    init() {
        let frameworkPaths: [String] = [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        ]
        frameworkHandles = frameworkPaths.compactMap { path in
            path.withCString { dlopen($0, RTLD_LAZY | RTLD_LOCAL) }
        }
        configureDisplayEnabled = Self.resolveConfigureDisplayEnabled(
            handles: frameworkHandles
        )
        if configureDisplayEnabled == nil {
            SystemCapabilityRegistry.shared.reportUnavailable(
                .displayIsolation,
                reason: "display isolation symbol unavailable"
            )
        } else {
            SystemCapabilityRegistry.shared.reportAvailable(.displayIsolation)
        }
        getDisplayList = Self.resolveSymbol(
            handles: frameworkHandles,
            names: ["CGSGetDisplayList", "SLSGetDisplayList"],
            as: GetDisplayListFunction.self
        )
    }

    private static func resolveConfigureDisplayEnabled(
        handles: [UnsafeMutableRawPointer]
    ) -> ConfigureDisplayEnabledFunction? {
        for symbolName in ["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"] {
            if let function = resolveSymbol(
                handles: handles,
                names: [symbolName],
                as: ConfigureDisplayEnabledFunction.self
            ) {
                AppLogger.ui.notice("Using display isolation API: \(symbolName, privacy: .public)")
                return function
            }
        }
        AppLogger.ui.error("Display isolation API is unavailable; using mirror fallback")
        return nil
    }

    private static func resolveSymbol<Function>(
        handles: [UnsafeMutableRawPointer],
        names: [String],
        as type: Function.Type
    ) -> Function? {
        for handle in handles {
            for name in names {
                if let symbol = dlsym(handle, name) {
                    return unsafeBitCast(symbol, to: type)
                }
            }
        }
        return nil
    }

    func setEnabled(
        _ enabled: Bool,
        displayID: CGDirectDisplayID,
        mirrorTargetID: CGDirectDisplayID?,
        previousBrightness: Float?
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if enabled {
            guard let mirrorTargetID else { return false }
            guard CGDisplayIsBuiltin(displayID) == 1 || states[displayID] != nil else {
                return false
            }

            let displayIsAlreadyIsolated = !onlineDisplayIDs().contains(displayID)
                || CGDisplayIsActive(displayID) == 0
            if displayIsAlreadyIsolated {
                states[displayID] = IsolationState(
                    previousBrightness: states[displayID]?.previousBrightness ?? previousBrightness,
                    mode: .disconnected,
                    isPersistent: true
                )
                return true
            }

            _ = configureDisplay(
                displayID: displayID,
                enabled: false,
                completionOption: BuiltInDisplayConfigurationPolicy.isolationOption
            )
            if waitForTargetState(displayID: displayID, blackoutEnabled: true) {
                states[displayID] = IsolationState(
                    previousBrightness: states[displayID]?.previousBrightness ?? previousBrightness,
                    mode: .disconnected,
                    isPersistent: true
                )
                return true
            }

            let didMirror = configureMirroring(displayID: displayID, mirrorTargetID: mirrorTargetID)
            if didMirror {
                states[displayID] = IsolationState(
                    previousBrightness: states[displayID]?.previousBrightness ?? previousBrightness,
                    mode: .mirrored,
                    isPersistent: false
                )
            }
            return didMirror
        }

        guard let state = states[displayID] else {
            // A restart loses the in-memory isolation mode. Clear either
            // possible fallback, enable the display, then verify the topology.
            _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
            _ = restoreDisconnectedDisplay(displayID: displayID)
            return waitForTargetState(displayID: displayID, blackoutEnabled: false)
        }
        switch state.mode {
        case .disconnected:
            _ = restoreDisconnectedDisplay(displayID: displayID)
        case .mirrored:
            _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
        }
        return waitForTargetState(displayID: displayID, blackoutEnabled: false)
    }

    func restoreBrightness(for displayID: CGDirectDisplayID) -> Float? {
        stateLock.withLock {
            states.removeValue(forKey: displayID)?.previousBrightness
        }
    }

    func isUsingMirrorFallback(displayID: CGDirectDisplayID) -> Bool {
        stateLock.withLock {
            states[displayID]?.mode == .mirrored
        }
    }

    func hasSettledIsolation(displayID: CGDirectDisplayID) -> Bool {
        stateLock.withLock {
            guard let state = states[displayID] else { return false }
            return state.isPersistent || state.mode == .mirrored
        }
    }

    func clearAll() -> [CGDirectDisplayID: Float] {
        stateLock.lock()
        defer { stateLock.unlock() }

        let previousStates = states
        for (displayID, state) in previousStates {
            switch state.mode {
            case .disconnected:
                _ = restoreDisconnectedDisplay(displayID: displayID)
            case .mirrored:
                _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
            }
            if waitForTargetState(displayID: displayID, blackoutEnabled: false) {
                states.removeValue(forKey: displayID)
            }
        }

        return previousStates.reduce(into: [:]) { result, entry in
            if states[entry.key] == nil, let brightness = entry.value.previousBrightness {
                result[entry.key] = brightness
            }
        }
    }

    func isRestored(displayID: CGDirectDisplayID) -> Bool {
        isDisplayRestored(displayID)
    }

    func removeRestoredStates(
        candidates: Set<CGDirectDisplayID>
    ) -> Set<CGDirectDisplayID> {
        stateLock.withLock {
            let restoredIDs = Set(candidates.filter {
                CGDisplayIsBuiltin($0) != 1 || isDisplayRestored($0)
            })
            for displayID in restoredIDs {
                states.removeValue(forKey: displayID)
            }
            return restoredIDs
        }
    }

    private func restoreDisconnectedDisplay(displayID: CGDirectDisplayID) -> Bool {
        // Commit the enabled state even when macOS has already lit the panel.
        // Otherwise a stale permanent isolation can disable it again at the
        // next login-window transition.
        let permanentRequestSucceeded = configureDisplay(
            displayID: displayID,
            enabled: true,
            completionOption: BuiltInDisplayConfigurationPolicy.restorationOption
        )
        if isDisplayRestored(displayID) {
            return true
        }

        AppLogger.ui.notice(
            "Permanent restore did not activate built-in display ID \(displayID); retrying for this session"
        )
        let sessionRequestSucceeded = configureDisplay(
            displayID: displayID,
            enabled: true,
            completionOption: BuiltInDisplayConfigurationPolicy.fallbackRestorationOption
        )
        return permanentRequestSucceeded || sessionRequestSucceeded
    }

    private func configureDisplay(
        displayID: CGDirectDisplayID,
        enabled: Bool,
        completionOption: CGConfigureOption = .forSession
    ) -> Bool {
        guard let configureDisplayEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return false
        }

        let configureResult = configureDisplayEnabled(config, displayID, enabled)
        guard configureResult == .success else {
            AppLogger.ui.error(
                "Display topology request failed for ID \(displayID), enabled: \(enabled, privacy: .public), error: \(configureResult.rawValue, privacy: .public)"
            )
            CGCancelDisplayConfiguration(config)
            return false
        }

        let completionResult = CGCompleteDisplayConfiguration(config, completionOption)
        if completionResult != .success {
            // WindowServer can apply this private operation while returning a
            // generic completion error. The configuration object is consumed by
            // CGCompleteDisplayConfiguration, so verification decides success.
            AppLogger.ui.notice(
                "Display topology completion failed for ID \(displayID), enabled: \(enabled, privacy: .public), error: \(completionResult.rawValue, privacy: .public)"
            )
            return false
        }
        return true
    }

    func allDisplayIDs() -> [CGDirectDisplayID] {
        guard let getDisplayList else {
            return Array(onlineDisplayIDs())
        }

        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success, count > 0 else {
            return Array(onlineDisplayIDs())
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard getDisplayList(count, &ids, &count) == .success else {
            return Array(onlineDisplayIDs())
        }
        return Array(ids.prefix(Int(count))).filter { $0 != kCGNullDirectDisplay }
    }

    private func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            return []
        }
        return Set(ids.prefix(Int(count)))
    }

    private func isDisplayRestored(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsActive(displayID) == 1
            && CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay
    }

    private func waitForTargetState(
        displayID: CGDirectDisplayID,
        blackoutEnabled: Bool
    ) -> Bool {
        for delay in [0, 20_000, 80_000, 200_000] as [useconds_t] {
            if delay > 0 {
                usleep(delay)
            }
            if BuiltInDisplayTopologyResult.reachedTarget(
                targetBlackoutEnabled: blackoutEnabled,
                displayIsRestored: isDisplayRestored(displayID)
            ) {
                return true
            }
        }
        return false
    }

    private func configureMirroring(displayID: CGDirectDisplayID, mirrorTargetID: CGDirectDisplayID?) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return false
        }

        let target = mirrorTargetID ?? kCGNullDirectDisplay
        CGConfigureDisplayMirrorOfDisplay(config, displayID, target)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result != .success {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return true
    }

    deinit {
        for handle in frameworkHandles {
            dlclose(handle)
        }
    }
}

nonisolated private final class DisplayServicesBridge: Sendable {
    func getBrightness(displayID: CGDirectDisplayID) -> Float? {
        var value: Float = -1
        let result = DisplayServicesGetBrightness(displayID, &value)
        guard result == 0, value >= 0 else {
            return nil
        }
        return min(1, max(0, value))
    }

    func setBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        let clampedValue = min(1, max(0, value))
        return DisplayServicesSetBrightness(displayID, clampedValue) == 0
    }
}
