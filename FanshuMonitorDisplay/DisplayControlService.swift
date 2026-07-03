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
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let name = displayName(for: id, isBuiltIn: isBuiltIn)
            let storageID = displayStorageID(for: id, name: name, isBuiltIn: isBuiltIn)
            let appleBrightness = isBuiltIn ? displayServices.getBrightness(displayID: id) : nil
            let hasDDCService = !isBuiltIn && ddc.hasService(for: id)
            let ddcBrightness = isBuiltIn ? nil : ddc.read(.brightness, displayID: id)
            let ddcVolume = isBuiltIn ? nil : ddc.read(.volume, displayID: id)
            let ddcContrast = isBuiltIn ? nil : ddc.read(.contrast, displayID: id)
            let storedBrightness = storedValue(for: .brightness, displayStorageID: storageID)
            let storedVolume = storedValue(for: .volume, displayStorageID: storageID)
            let storedContrast = storedValue(for: .contrast, displayStorageID: storageID)

            return ControlledDisplay(
                id: id,
                storageID: storageID,
                name: name,
                isBuiltIn: isBuiltIn,
                supportsBrightness: isBuiltIn ? appleBrightness != nil : (ddcBrightness != nil || storedBrightness != nil || hasDDCService),
                supportsVolume: !isBuiltIn && (ddcVolume != nil || storedVolume != nil),
                supportsContrast: !isBuiltIn && (ddcContrast != nil || storedContrast != nil),
                brightness: appleBrightness.map { Double($0 * 100) }
                    ?? softwareDimming.userBrightness(for: id, storedUserBrightness: storedBrightness, hardwareBrightness: ddcBrightness)
                    ?? storedBrightness
                    ?? DisplayControlKind.brightness.defaultValue,
                volume: ddcVolume
                    ?? storedVolume
                    ?? DisplayControlKind.volume.defaultValue,
                contrast: ddcContrast
                    ?? storedContrast
                    ?? DisplayControlKind.contrast.defaultValue,
                brightnessUnavailableReason: isBuiltIn ? "系统亮度服务不可用" : (hasDDCService ? nil : "未匹配到 DDC/CI 服务"),
                volumeUnavailableReason: isBuiltIn ? "内建屏不支持 DDC 音量" : (ddcVolume != nil || storedVolume != nil ? nil : "显示器未响应音量 VCP"),
                contrastUnavailableReason: isBuiltIn ? "内建屏不支持 DDC 对比度" : (ddcContrast != nil || storedContrast != nil ? nil : "显示器未响应对比度 VCP")
            )
        }
    }

    func setValue(_ value: Double, for control: DisplayControlKind, display: ControlledDisplay) -> Bool {
        guard display.supports(control) else {
            return false
        }

        if display.isBuiltIn {
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

        let success = ddc.write(writeValue, for: control, displayID: display.id)
        if success {
            if control == .brightness, softwareDimmingEnabled {
                softwareDimming.setUserBrightness(value, for: display.id)
            }
            saveStoredValue(value, for: control, displayStorageID: display.storageID)
        }
        return success
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
}

enum DisplayDimmingCalibration {
    static let hardwareZeroUserBrightness: Double = 15
    static let maximumOverlayOpacity: Double = 0.70
}

private final class DisplaySoftwareDimmingService {
    private let dimmingThreshold: Double = DisplayDimmingCalibration.hardwareZeroUserBrightness
    private let maximumOverlayOpacity: Double = DisplayDimmingCalibration.maximumOverlayOpacity
    private let lock = NSLock()
    private var requestedBrightness: [CGDirectDisplayID: Double] = [:]
    @MainActor private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]

    func userBrightness(
        for displayID: CGDirectDisplayID,
        storedUserBrightness: Double?,
        hardwareBrightness: Double?
    ) -> Double? {
        if let cached = cachedBrightness(for: displayID) {
            return cached
        }

        if let storedUserBrightness, storedUserBrightness < dimmingThreshold {
            setUserBrightness(storedUserBrightness, for: displayID)
            return storedUserBrightness
        }

        guard let hardwareBrightness else { return nil }
        return min(100, max(0, dimmingThreshold + (hardwareBrightness / 100) * (100 - dimmingThreshold)))
    }

    func hardwareBrightness(forUserBrightness userBrightness: Double) -> Double {
        let clamped = min(100, max(0, userBrightness))
        guard clamped > dimmingThreshold else { return 0 }
        return min(100, max(0, (clamped - dimmingThreshold) / (100 - dimmingThreshold) * 100))
    }

    func setUserBrightness(_ userBrightness: Double, for displayID: CGDirectDisplayID) {
        let clamped = min(100, max(0, userBrightness))
        lock.lock()
        requestedBrightness[displayID] = clamped
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.apply(userBrightness: clamped, for: displayID)
        }
    }

    func sync(with displays: [ControlledDisplay]) {
        let displayIDs = Set(displays.map(\.id))
        let brightnessByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.brightness) })

        lock.lock()
        requestedBrightness = requestedBrightness.filter { displayIDs.contains($0.key) }
        for (displayID, brightness) in brightnessByID where CGDisplayIsBuiltin(displayID) == 0 {
            requestedBrightness[displayID] = brightness
        }
        let values = requestedBrightness
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for (displayID, brightness) in values {
                self.apply(userBrightness: brightness, for: displayID)
            }
            self.removeMissingWindows(keeping: displayIDs)
        }
    }

    func clear(displayID: CGDirectDisplayID) {
        lock.lock()
        requestedBrightness[displayID] = nil
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.removeWindow(for: displayID)
        }
    }

    func clearAll() {
        lock.lock()
        requestedBrightness.removeAll()
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
    private func apply(userBrightness: Double, for displayID: CGDirectDisplayID) {
        guard CGDisplayIsBuiltin(displayID) == 0 else {
            removeWindow(for: displayID)
            return
        }

        let opacity = overlayOpacity(for: userBrightness)
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
        let clamped = min(dimmingThreshold, max(0, userBrightness))
        return (1 - clamped / dimmingThreshold) * maximumOverlayOpacity
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
        window.level = .screenSaver
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
