import Foundation

enum LockScreenDayScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case everyDay
    case weekdays
    case weekends
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyDay: "每天"
        case .weekdays: "工作日"
        case .weekends: "周末"
        case .custom: "自选日期"
        }
    }
}

struct LockScreenPolicy: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var isEnabled: Bool
    var dayScope: LockScreenDayScope
    var customWeekdays: Set<Int>
    var startMinutes: Int
    var endMinutes: Int
    var idleMinutes: Int

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        dayScope: LockScreenDayScope = .everyDay,
        customWeekdays: Set<Int>? = nil,
        startMinutes: Int = 9 * 60,
        endMinutes: Int = 18 * 60,
        idleMinutes: Int = 10
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.dayScope = dayScope
        self.customWeekdays = Self.validWeekdays(customWeekdays ?? Self.defaultWeekdays(for: dayScope))
        self.startMinutes = Self.clampedMinutes(startMinutes)
        self.endMinutes = Self.clampedMinutes(endMinutes)
        self.idleMinutes = min(1_440, max(1, idleMinutes))
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

        return matchesTime && applies(to: calendar.component(.weekday, from: effectiveDate))
    }

    func transitionDates(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        guard isEnabled, hasValidTimeRange else { return [] }

        let startOfToday = calendar.startOfDay(for: date)
        var dates: [Date] = []
        for dayOffset in 0...8 {
            guard let startDate = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                  applies(to: calendar.component(.weekday, from: startDate)),
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

    static func minutes(from text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...24).contains(hour),
              (0...59).contains(minute),
              hour < 24 || minute == 0 else {
            return nil
        }
        return hour == 24 ? 0 : hour * 60 + minute
    }

    mutating func toggleCustomWeekday(_ weekday: Int) {
        guard (1...7).contains(weekday) else { return }
        if customWeekdays.contains(weekday) {
            customWeekdays.remove(weekday)
        } else {
            customWeekdays.insert(weekday)
        }
    }

    private func applies(to weekday: Int) -> Bool {
        switch dayScope {
        case .everyDay:
            true
        case .weekdays:
            (2...6).contains(weekday)
        case .weekends:
            weekday == 1 || weekday == 7
        case .custom:
            customWeekdays.contains(weekday)
        }
    }

    private static func defaultWeekdays(for dayScope: LockScreenDayScope) -> Set<Int> {
        switch dayScope {
        case .everyDay: Set(1...7)
        case .weekdays: Set(2...6)
        case .weekends: [1, 7]
        case .custom: Set(2...6)
        }
    }

    private static func validWeekdays(_ weekdays: Set<Int>) -> Set<Int> {
        Set(weekdays.filter { (1...7).contains($0) })
    }

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, dayScope, customWeekdays, startMinutes, endMinutes, idleMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        dayScope = try container.decode(LockScreenDayScope.self, forKey: .dayScope)
        customWeekdays = Self.validWeekdays(
            try container.decodeIfPresent(Set<Int>.self, forKey: .customWeekdays)
                ?? Self.defaultWeekdays(for: dayScope)
        )
        startMinutes = Self.clampedMinutes(try container.decode(Int.self, forKey: .startMinutes))
        endMinutes = Self.clampedMinutes(try container.decode(Int.self, forKey: .endMinutes))
        idleMinutes = min(1_440, max(1, try container.decode(Int.self, forKey: .idleMinutes)))
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

extension ScreenSaverLockBaseline {
    var idleMinutes: Int? {
        idleTime.map { max(1, Int((Double($0) / 60).rounded(.up))) }
    }

    var passwordDelayText: String {
        guard let askForPassword else { return "系统默认" }
        guard askForPassword else { return "不要求密码" }
        guard let askForPasswordDelay else { return "系统默认" }
        return askForPasswordDelay == 0 ? "立即" : "\(askForPasswordDelay) 秒后"
    }
}
