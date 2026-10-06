import Foundation

struct CodexQuotaPresentation: Equatable, Sendable {
    let fiveHourPercent: Double?
    let fiveHourText: String
    let weeklyPercent: Double?
    let weeklyText: String
    let weeklyResetText: String

    init(metrics: [MonitorMetric]) {
        let values = Dictionary(metrics.map { ($0.name, $0.value) }, uniquingKeysWith: { _, latest in latest })
        fiveHourPercent = Self.percent(from: values["five-hour"])
        fiveHourText = Self.displayValue(values["five-hour"])
        weeklyPercent = Self.percent(from: values["weekly"])
        weeklyText = Self.displayValue(values["weekly"])
        weeklyResetText = Self.weeklyResetDisplayValue(values["weekly-reset"])
    }

    var hasFiveHourQuota: Bool {
        fiveHourPercent != nil
    }

    var hasWeeklyQuota: Bool {
        weeklyPercent != nil
    }

    var progressValue: Double {
        fiveHourPercent ?? weeklyPercent ?? 0
    }

    private static func percent(from value: String?) -> Double? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
        guard !normalized.isEmpty,
              normalized != "--",
              let percent = Double(normalized),
              (0...100).contains(percent) else {
            return nil
        }
        return percent
    }

    private static func displayValue(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "--"
        }
        return value
    }

    private static func weeklyResetDisplayValue(_ value: String?) -> String {
        let text = displayValue(value)
        let components = text.split(separator: ".")
        guard components.count == 3, components[0].count == 4,
              Int(components[0]) != nil,
              let month = Int(components[1]), (1...12).contains(month),
              let day = Int(components[2]), (1...31).contains(day) else { return text }
        return "\(month).\(day)"
    }
}
