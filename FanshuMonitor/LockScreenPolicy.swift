import Foundation

enum LockScreenDayScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case everyDay
    case weekdays
    case weekends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyDay: "每天"
        case .weekdays: "工作日"
        case .weekends: "周末"
        }
    }

    func contains(weekday: Int) -> Bool {
        switch self {
        case .everyDay:
            true
        case .weekdays:
            (2...6).contains(weekday)
        case .weekends:
            weekday == 1 || weekday == 7
        }
    }
}

struct LockScreenPolicy: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var isEnabled: Bool
    var dayScope: LockScreenDayScope
    var startMinutes: Int
    var endMinutes: Int
    var idleMinutes: Int

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        dayScope: LockScreenDayScope = .everyDay,
        startMinutes: Int = 9 * 60,
        endMinutes: Int = 18 * 60,
        idleMinutes: Int = 10
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.dayScope = dayScope
        self.startMinutes = Self.clampedMinutes(startMinutes)
        self.endMinutes = Self.clampedMinutes(endMinutes)
        self.idleMinutes = min(120, max(1, idleMinutes))
    }

    var crossesMidnight: Bool {
        endMinutes < startMinutes
    }

    var hasValidTimeRange: Bool {
        startMinutes != endMinutes
    }

    var timeRangeText: String {
        "\(Self.clockText(startMinutes)) - \(Self.clockText(endMinutes))"
    }

    func isActive(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard isEnabled, hasValidTimeRange else { return false }

        let currentMinutes = calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
        let matchesTime: Bool
        let effectiveDate: Date

        if crossesMidnight {
            matchesTime = currentMinutes >= startMinutes || currentMinutes < endMinutes
            effectiveDate = currentMinutes < endMinutes
                ? calendar.date(byAdding: .day, value: -1, to: date) ?? date
                : date
        } else {
            matchesTime = currentMinutes >= startMinutes && currentMinutes < endMinutes
            effectiveDate = date
        }

        return matchesTime && dayScope.contains(weekday: calendar.component(.weekday, from: effectiveDate))
    }

    func transitionDates(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        guard isEnabled, hasValidTimeRange else { return [] }

        let startOfToday = calendar.startOfDay(for: date)
        var dates: [Date] = []
        for dayOffset in 0...8 {
            guard let startDate = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                  dayScope.contains(weekday: calendar.component(.weekday, from: startDate)),
                  let policyStart = calendar.date(byAdding: .minute, value: startMinutes, to: startDate) else {
                continue
            }

            let endDayOffset = crossesMidnight ? 1 : 0
            guard let policyEndBase = calendar.date(byAdding: .day, value: endDayOffset, to: startDate),
                  let policyEnd = calendar.date(byAdding: .minute, value: endMinutes, to: policyEndBase) else {
                continue
            }

            if policyStart > date { dates.append(policyStart) }
            if policyEnd > date { dates.append(policyEnd) }
        }
        return dates
    }

    static func clockText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private static func clampedMinutes(_ value: Int) -> Int {
        min(23 * 60 + 59, max(0, value))
    }
}

struct ScreenSaverLockBaseline: Codable, Equatable, Sendable {
    var idleTime: Int?
    var askForPassword: Bool?
    var askForPasswordDelay: Int?
}
