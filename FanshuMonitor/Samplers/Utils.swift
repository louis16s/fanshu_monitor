import Foundation

nonisolated func percent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

nonisolated func bytes(_ value: Double) -> String {
    makeByteFormatter(style: .file).string(fromByteCount: Int64(max(0, value)))
}

nonisolated func memoryBytes(_ value: Double) -> String {
    makeByteFormatter(style: .memory).string(fromByteCount: Int64(max(0, value)))
}

nonisolated func wattString(_ value: Double?, rounded: Bool = false) -> String {
    guard let value else {
        return "--"
    }
    if rounded {
        return "\(Int(value.rounded())) W"
    }
    return "\(String(format: "%.1f", value)) W"
}

nonisolated func wattStringAllowZero(_ value: Double?) -> String {
    guard let value else {
        return "--"
    }
    return value == 0 ? "0 W" : "\(String(format: "%.1f", value)) W"
}

nonisolated func nonZeroWatts(_ value: Double?) -> Double? {
    guard let value, value >= 0.05 else {
        return nil
    }
    return value
}

nonisolated private func makeByteFormatter(style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = style
    return formatter
}

nonisolated func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
        value
    case let value as Float:
        Double(value)
    case let value as Int:
        Double(value)
    case let value as Int64:
        Double(value)
    case let value as UInt64:
        Double(value)
    case let value as NSNumber:
        value.doubleValue
    default:
        nil
    }
}

nonisolated func signedDoubleValue(_ value: Any?) -> Double? {
    switch value {
    case let value as Int:
        return Double(value)
    case let value as Int64:
        return Double(value)
    case let value as UInt64:
        if value > UInt64(Int64.max) {
            return Double(Int64(bitPattern: value))
        }
        return Double(value)
    case let value as NSNumber:
        let unsigned = value.uint64Value
        if unsigned > UInt64(Int64.max) {
            return Double(Int64(bitPattern: unsigned))
        }
        return value.doubleValue
    default:
        return doubleValue(value)
    }
}

nonisolated func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
        value
    case let value as Int64:
        Int(value)
    case let value as UInt64:
        Int(value)
    case let value as NSNumber:
        value.intValue
    default:
        nil
    }
}

nonisolated func seedSamples(_ value: Double) -> [Double] {
    Array(repeating: min(100, max(0, value)), count: 28)
}
