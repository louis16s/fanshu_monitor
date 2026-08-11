import CoreGraphics
import Foundation

nonisolated struct ControlledDisplay: Identifiable, Sendable {
    let id: CGDirectDisplayID
    let storageID: String
    let name: String
    let kind: DisplayKind
    let isBuiltIn: Bool
    let usesNativeBrightness: Bool
    var supportsBrightness: Bool
    var supportsVolume: Bool
    var supportsContrast: Bool
    var brightness: Double
    var volume: Double
    var contrast: Double
    var brightnessUnavailableReason: String?
    var volumeUnavailableReason: String?
    var contrastUnavailableReason: String?
    var capabilities: DisplayCapabilities?

    func supports(_ control: DisplayControlKind) -> Bool {
        switch control {
        case .brightness:
            supportsBrightness
        case .volume:
            supportsVolume
        case .contrast:
            supportsContrast
        }
    }

    func value(for control: DisplayControlKind) -> Double {
        switch control {
        case .brightness:
            brightness
        case .volume:
            volume
        case .contrast:
            contrast
        }
    }

    mutating func setValue(_ value: Double, for control: DisplayControlKind) {
        switch control {
        case .brightness:
            brightness = value
        case .volume:
            volume = value
        case .contrast:
            contrast = value
        }
    }

    mutating func setSupported(_ isSupported: Bool, for control: DisplayControlKind) {
        switch control {
        case .brightness:
            supportsBrightness = isSupported
        case .volume:
            supportsVolume = isSupported
        case .contrast:
            supportsContrast = isSupported
        }
    }
}

nonisolated struct DisplayCapabilities: Equatable, Sendable {
    let resolution: String
    let refreshRate: String
    let dynamicRange: String
    let colorSpace: String
    let connection: String

    var summary: String {
        [resolution, refreshRate, dynamicRange, colorSpace]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

nonisolated enum DisplayCapabilityFormatter {
    static func resolution(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "--" }
        return "\(width)×\(height)"
    }

    static func refreshRate(
        current: Double,
        maximumFramesPerSecond: Int,
        maximumRefreshInterval: TimeInterval
    ) -> String {
        let maximum = maximumFramesPerSecond > 0
            ? maximumFramesPerSecond
            : Int(current.rounded())
        guard maximum > 0 else { return "-- Hz" }

        let minimum = maximumRefreshInterval > 0
            ? Int((1 / maximumRefreshInterval).rounded())
            : maximum
        if minimum >= 24, minimum < maximum {
            return "\(minimum)–\(maximum) Hz"
        }
        return "\(maximum) Hz"
    }

    static func colorSpace(_ localizedName: String?) -> String {
        guard let localizedName, !localizedName.isEmpty else { return "--" }
        if localizedName.localizedCaseInsensitiveContains("display p3") { return "Display P3" }
        if localizedName.localizedCaseInsensitiveContains("srgb") { return "sRGB" }
        if localizedName.localizedCaseInsensitiveContains("adobe rgb") { return "Adobe RGB" }
        return localizedName
    }

    static func connection(for kind: DisplayKind) -> String {
        switch kind {
        case .builtIn: "内置"
        case .appleNative: "原生"
        case .externalDDC: "DDC"
        case .virtual, .dummy: "虚拟"
        case .unsupported: "外接"
        }
    }
}

nonisolated(unsafe) let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
    guard let userInfo else { return }
    guard !flags.contains(.beginConfigurationFlag) else { return }
    let controller = Unmanaged<DisplayControlController>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in
        controller.handleDisplayReconfiguration(displayID: displayID, flags: flags)
    }
}

nonisolated enum DisplayControlKind: Hashable, CaseIterable, Sendable {
    case brightness
    case volume
    case contrast

    var defaultValue: Double {
        switch self {
        case .brightness:
            50
        case .volume:
            40
        case .contrast:
            75
        }
    }

    var storageKey: String {
        switch self {
        case .brightness:
            "brightness"
        case .volume:
            "volume"
        case .contrast:
            "contrast"
        }
    }
}

nonisolated struct ControlKey: Hashable, Sendable {
    let displayID: CGDirectDisplayID
    let control: DisplayControlKind
}

nonisolated enum DisplayValueChangePolicy {
    static let minimumVisibleDelta = 0.1

    static func shouldPublish(current: Double, next: Double) -> Bool {
        abs(next - current) >= minimumVisibleDelta
    }
}

nonisolated enum DisplayNativeBrightnessSyncPolicy {
    static let intervalMilliseconds = 200

    static func shouldRun(
        panelVisible: Bool,
        moduleVisible: Bool,
        brightnessControlEnabled: Bool,
        hasNativeBrightnessDisplay: Bool
    ) -> Bool {
        panelVisible
            && moduleVisible
            && brightnessControlEnabled
            && hasNativeBrightnessDisplay
    }
}

nonisolated enum DisplayHeaderBrightnessPolicy {
    static func targetID(
        displays: [ControlledDisplay],
        blackedOutDisplayIDs: Set<CGDirectDisplayID>
    ) -> CGDirectDisplayID? {
        let activeDisplays = displays.filter { !blackedOutDisplayIDs.contains($0.id) }
        guard activeDisplays.count == 1,
              let display = activeDisplays.first,
              display.supportsBrightness
        else {
            return nil
        }
        return display.id
    }
}

nonisolated enum BuiltInDisplayRestorePolicy {
    static let disconnectedExternalBrightness = 35.0
    static let topologyWatchdogInterval: TimeInterval = 5
    static let topologyRetryDelays: [TimeInterval] = [0, 0.05, 0.2, 0.5, 1, 2]
    static let brightnessRetryDelays: [TimeInterval] = [0, 0.05, 0.2, 0.5, 1.0, 2.0]

    static func shouldRestore(
        externalDisplayCount: Int,
        blackoutDesired: Bool,
        isolatedDisplayCount: Int
    ) -> Bool {
        externalDisplayCount == 0
            && (blackoutDesired || isolatedDisplayCount > 0)
    }
}

nonisolated enum DisplayDisconnectRecoveryPolicy {
    static func shouldForceRestore(
        isRemoval: Bool,
        removedDisplayID: CGDirectDisplayID,
        cachedBuiltInDisplayID: CGDirectDisplayID?,
        knownExternalDisplayIDs: Set<CGDirectDisplayID>
    ) -> Bool {
        guard isRemoval,
              removedDisplayID != cachedBuiltInDisplayID,
              knownExternalDisplayIDs.count == 1
        else {
            return false
        }
        return knownExternalDisplayIDs.contains(removedDisplayID)
    }
}

nonisolated enum DisplayHardwareDisconnectRecoveryPolicy {
    static let confirmedRemovalDelay: TimeInterval = 0.06
    static let unknownChangeDelay: TimeInterval = 0.18

    static func shouldForceRestore(
        externalServiceCount: Int?,
        isolatedDisplayCount: Int,
        builtInDisplayIsOffline: Bool
    ) -> Bool {
        externalServiceCount == 0
            && (isolatedDisplayCount > 0 || builtInDisplayIsOffline)
    }
}

nonisolated enum BuiltInBlackoutIntentPolicy {
    static func shouldSuspendForMissingExternal(
        externalDisplayCount: Int,
        blackoutDesired: Bool,
        isolatedDisplayCount: Int,
        builtInDisplayIsOffline: Bool
    ) -> Bool {
        externalDisplayCount == 0
            && blackoutDesired
            && isolatedDisplayCount == 0
            && !builtInDisplayIsOffline
    }
}

nonisolated enum BuiltInDisconnectRecoveryResult: Sendable, Equatable {
    case externalDisplayPresent
    case restored(displayID: CGDirectDisplayID)
    case brightnessPending(displayID: CGDirectDisplayID)
    case builtInDisplayUnavailable
}

nonisolated enum BuiltInDisplayTopologyResult {
    static func reachedTarget(
        targetBlackoutEnabled: Bool,
        displayIsRestored: Bool
    ) -> Bool {
        targetBlackoutEnabled ? !displayIsRestored : displayIsRestored
    }
}

nonisolated struct BuiltInDisplayIdentity: Codable, Equatable, Sendable {
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32
    let unitNumber: UInt32

    init(vendorID: UInt32, modelID: UInt32, serialNumber: UInt32, unitNumber: UInt32) {
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
        self.unitNumber = unitNumber
    }

    init(displayID: CGDirectDisplayID) {
        vendorID = CGDisplayVendorNumber(displayID)
        modelID = CGDisplayModelNumber(displayID)
        serialNumber = CGDisplaySerialNumber(displayID)
        unitNumber = CGDisplayUnitNumber(displayID)
    }

    func matches(displayID: CGDirectDisplayID) -> Bool {
        self == BuiltInDisplayIdentity(displayID: displayID)
    }
}

nonisolated struct BuiltInDisplayRecoverySnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let identity: BuiltInDisplayIdentity
    let lastRuntimeID: CGDirectDisplayID
    let brightness: Double

    init(displayID: CGDirectDisplayID, brightness: Double) {
        self.init(
            identity: BuiltInDisplayIdentity(displayID: displayID),
            lastRuntimeID: displayID,
            brightness: brightness
        )
    }

    init(
        identity: BuiltInDisplayIdentity,
        lastRuntimeID: CGDirectDisplayID,
        brightness: Double
    ) {
        schemaVersion = Self.schemaVersion
        self.identity = identity
        self.lastRuntimeID = lastRuntimeID
        self.brightness = min(1, max(0, brightness))
    }
}

struct RecentDisplayValue {
    let value: Double
    let date: Date
}
