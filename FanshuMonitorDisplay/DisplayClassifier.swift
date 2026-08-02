import CoreGraphics
import Foundation

nonisolated enum DisplayKind: Equatable, Sendable {
    case builtIn
    case appleNative
    case externalDDC
    case virtual
    case dummy
    case unsupported
}

struct DisplayClassifier {
    var probeNativeBrightness: (CGDirectDisplayID) -> Bool
    var isBuiltInDisplay: (CGDirectDisplayID) -> Bool
    var infoProvider: (CGDirectDisplayID) -> [String: Any]

    init(
        probeNativeBrightness: @escaping (CGDirectDisplayID) -> Bool = DisplayClassifier.defaultProbeNativeBrightness,
        isBuiltInDisplay: @escaping (CGDirectDisplayID) -> Bool = { CGDisplayIsBuiltin($0) != 0 },
        infoProvider: @escaping (CGDirectDisplayID) -> [String: Any] = DisplayClassifier.defaultInfo
    ) {
        self.probeNativeBrightness = probeNativeBrightness
        self.isBuiltInDisplay = isBuiltInDisplay
        self.infoProvider = infoProvider
    }

    func classify(displayID: CGDirectDisplayID) -> DisplayKind {
        if isBuiltInDisplay(displayID) {
            return .builtIn
        }

        let info = infoProvider(displayID)
        if boolValue(info["kCGDisplayIsVirtualDevice"]) ||
            boolValue(info["kCGDisplayIsAirPlay"]) {
            return .virtual
        }

        if isDummy(info: info) {
            return .dummy
        }

        if probeNativeBrightness(displayID) {
            return .appleNative
        }

        return .externalDDC
    }

    private func isDummy(info: [String: Any]) -> Bool {
        let names = info["DisplayProductName"] as? [String: String] ?? [:]
        if names.values.contains(where: { $0.localizedCaseInsensitiveContains("dummy") }) {
            return true
        }
        if let vendor = integerValue(info["DisplayVendorID"]), vendor == 0xF0F0 {
            return true
        }
        return false
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private func integerValue(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        return nil
    }

    nonisolated static func defaultProbeNativeBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        var brightness: Float = -1
        let result = DisplayServicesGetBrightness(displayID, &brightness)
        return result == 0 && brightness >= 0
    }

    nonisolated static func defaultInfo(_ displayID: CGDirectDisplayID) -> [String: Any] {
        CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as? [String: Any] ?? [:]
    }
}
