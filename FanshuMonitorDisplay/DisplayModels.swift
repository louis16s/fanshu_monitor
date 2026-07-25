import CoreGraphics
import Foundation

struct ControlledDisplay: Identifiable {
    let id: CGDirectDisplayID
    let storageID: String
    let name: String
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

nonisolated(unsafe) let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else { return }
    let controller = Unmanaged<DisplayControlController>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in
        controller.scheduleRefresh()
    }
}

nonisolated enum DisplayControlKind: Hashable, CaseIterable {
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

nonisolated struct ControlKey: Hashable {
    let displayID: CGDirectDisplayID
    let control: DisplayControlKind
}

struct RecentDisplayValue {
    let value: Double
    let date: Date
}
