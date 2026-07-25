import AppKit
import CoreGraphics
import Foundation
import OSLog

final class DisplayControlService {
    private let displayServices = DisplayServicesBridge()
    private let ddc = DisplayDDCBridge()
    private let defaults = UserDefaults.standard
    private let softwareDimming = DisplaySoftwareDimmingService()
    private let builtInBlackout = BuiltInDisplayBlackoutService()
    private let displayClassifier = DisplayClassifier()
    private lazy var ddcRangeStore = DisplayDDCRangeStore(defaults: defaults)
    var softwareDimmingEnabled = true

    func displays() -> [ControlledDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            AppLogger.ui.error("CGGetOnlineDisplayList failed")
            return []
        }

        let displayIDs = Array(ids.prefix(Int(count)))
        AppLogger.ui.info("Detected \(displayIDs.count) online displays")
        ddc.refresh(displayIDs: displayIDs)

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
            let appleBrightness = usesNativeBrightness ? displayServices.getBrightness(displayID: id) : nil
            let hasDDCService = usesDDC && ddc.hasService(for: id)
            let brightnessTemporarilyDisabled = usesDDC && ddc.isTemporarilyDisabled(.brightness, displayID: id)
            let volumeTemporarilyDisabled = usesDDC && ddc.isTemporarilyDisabled(.volume, displayID: id)
            let contrastTemporarilyDisabled = usesDDC && ddc.isTemporarilyDisabled(.contrast, displayID: id)
            let ddcBrightness = usesDDC ? ddc.read(.brightness, displayID: id) : nil
            let ddcVolume = usesDDC ? ddc.read(.volume, displayID: id) : nil
            let ddcContrast = usesDDC ? ddc.read(.contrast, displayID: id) : nil
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
                )
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
            let didMirror = builtInBlackout.setEnabled(
                true,
                displayID: display.id,
                mirrorTargetID: mirrorTarget.id,
                previousBrightness: previousBrightness
            )
            guard didMirror else {
                return false
            }
            _ = displayServices.setBrightness(displayID: display.id, value: 0)
            return didMirror
        }

        guard builtInBlackout.setEnabled(false, displayID: display.id, mirrorTargetID: nil, previousBrightness: nil) else {
            return false
        }
        let restoredBrightness = builtInBlackout.restoreBrightness(for: display.id) ?? Float(display.brightness / 100)
        _ = displayServices.setBrightness(displayID: display.id, value: restoredBrightness)
        return true
    }

    func syncBuiltInBlackouts(keeping displayIDs: Set<CGDirectDisplayID>, displays: [ControlledDisplay]) {
        builtInBlackout.sync(keeping: displayIDs)
        guard let mirrorTarget = displays.first(where: { !$0.isBuiltIn })?.id else { return }
        for displayID in displayIDs {
            _ = builtInBlackout.setEnabled(true, displayID: displayID, mirrorTargetID: mirrorTarget, previousBrightness: nil)
        }
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
        for displayID in displayIDs where CGDisplayIsBuiltin(displayID) != 0 {
            let previousBrightness = displayServices.getBrightness(displayID: displayID)
            if builtInBlackout.setEnabled(
                true,
                displayID: displayID,
                mirrorTargetID: mirrorTargetID,
                previousBrightness: previousBrightness
            ) {
                _ = displayServices.setBrightness(displayID: displayID, value: 0)
                appliedDisplayIDs.insert(displayID)
            }
        }
        return appliedDisplayIDs
    }

    func clearBuiltInBlackouts() {
        let brightnessByDisplayID = builtInBlackout.clearAll()
        for (displayID, brightness) in brightnessByDisplayID {
            _ = displayServices.setBrightness(displayID: displayID, value: brightness)
        }
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

struct DisplayDDCRangeStore {
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

enum DisplayDimmingCalibration {
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

private final class DisplaySoftwareDimmingService {
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

private final class BuiltInDisplayBlackoutService {
    private var previousBrightnessByDisplayID: [CGDirectDisplayID: Float] = [:]

    func setEnabled(
        _ enabled: Bool,
        displayID: CGDirectDisplayID,
        mirrorTargetID: CGDirectDisplayID?,
        previousBrightness: Float?
    ) -> Bool {
        guard CGDisplayIsBuiltin(displayID) != 0 else { return false }

        if enabled {
            guard let mirrorTargetID else { return false }
            let didConfigure = configureMirroring(displayID: displayID, mirrorTargetID: mirrorTargetID)
            if didConfigure, previousBrightnessByDisplayID[displayID] == nil {
                previousBrightnessByDisplayID[displayID] = previousBrightness
            }
            return didConfigure
        }

        return configureMirroring(displayID: displayID, mirrorTargetID: nil)
    }

    func restoreBrightness(for displayID: CGDirectDisplayID) -> Float? {
        previousBrightnessByDisplayID.removeValue(forKey: displayID)
    }

    func sync(keeping displayIDs: Set<CGDirectDisplayID>) {
        let removedIDs = Set(previousBrightnessByDisplayID.keys).subtracting(displayIDs)
        for displayID in removedIDs {
            _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
        }
        previousBrightnessByDisplayID = previousBrightnessByDisplayID.filter { displayIDs.contains($0.key) }
    }

    func clearAll() -> [CGDirectDisplayID: Float] {
        let brightnessByDisplayID = previousBrightnessByDisplayID
        previousBrightnessByDisplayID.removeAll()
        for displayID in brightnessByDisplayID.keys {
            _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
        }

        return brightnessByDisplayID
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
}

private final class DisplayServicesBridge {
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
