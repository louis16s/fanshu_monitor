import Foundation

nonisolated struct MetricID: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
}

nonisolated extension MetricID {
    static let activeTasks: Self = "active-tasks"
    static let batteryType: Self = "type"
    static let batteryStatus: Self = "status"
    static let plan: Self = "plan"
    static let fiveHour: Self = "five-hour"
    static let fiveHourReset: Self = "five-hour-reset"
    static let weekly: Self = "weekly"
    static let weeklyReset: Self = "weekly-reset"
    static let resetCredits: Self = "reset-credits"
}
