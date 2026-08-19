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
        guard let displayID = cachedOrDiscoverableBuiltInDisplayID() else { return false }
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

        // A permanently disabled built-in display can fail both the built-in
        // classification and the online-list query until WindowServer applies
        // the next topology update. The cached ID was written only after a
        // successful built-in classification, so it remains the safest
        // identity for restoring and presenting the row during this gap.
        if let cachedDisplayID = cachedBuiltInDisplayID(),
           builtInRecoverySnapshot() != nil {
            return cachedDisplayID
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

        if let info = PrivateDisplayAPI.shared.displayInfoDictionary(for: id),
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
