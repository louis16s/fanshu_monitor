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

nonisolated(unsafe) let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo else { return }
    guard !flags.contains(.beginConfigurationFlag) else { return }
    let controller = Unmanaged<DisplayControlController>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in
        controller.scheduleRefresh()
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
    static func shouldRestore(
        externalDisplayCount: Int,
        blackoutDesired: Bool,
        isolatedDisplayCount: Int
    ) -> Bool {
        externalDisplayCount == 0
            && (blackoutDesired || isolatedDisplayCount > 0)
    }
}

nonisolated enum BuiltInDisplayTopologyResult {
    static func succeeded(
        requestSucceeded: Bool,
        targetBlackoutEnabled: Bool,
        displayIsRestored: Bool
    ) -> Bool {
        requestSucceeded || (targetBlackoutEnabled ? !displayIsRestored : displayIsRestored)
    }
}

struct RecentDisplayValue {
    let value: Double
    let date: Date
}
