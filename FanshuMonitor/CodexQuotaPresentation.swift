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
        weeklyResetText = Self.displayValue(values["weekly-reset"])
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
}
