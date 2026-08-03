import Foundation

nonisolated enum LockScreenDayScope: String, CaseIterable, Codable, Identifiable, Sendable {
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

nonisolated enum LockScreenPowerCondition: String, CaseIterable, Codable, Identifiable, Sendable {
    case any
    case connected
    case battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "电源不限"
        case .connected: "接通电源"
        case .battery: "使用电池"
        }
    }

    var symbolName: String {
        switch self {
        case .any: "bolt.circle"
        case .connected: "powerplug"
        case .battery: "battery.100percent"
        }
    }

    func matches(_ state: SystemPowerSourceState) -> Bool {
        switch (self, state) {
        case (.any, _), (.connected, .connected), (.battery, .battery): true
        default: false
        }
    }

    func overlaps(_ other: LockScreenPowerCondition) -> Bool {
        switch (self, other) {
        case (.connected, .battery), (.battery, .connected): false
        default: true
        }
    }

    var waitingText: String {
        switch self {
        case .any: "等待规则生效"
        case .connected: "等待接通电源"
        case .battery: "等待切换到电池供电"
        }
    }
}

nonisolated enum SystemPowerSourceState: Equatable, Sendable {
    case connected
    case battery
    case unknown
}

nonisolated enum LockScreenPolicyStatus: Equatable, Sendable {
    case disabled
    case restored
    case systemSettingsChanged
    case systemSettingsBlocked
    case noRules
    case waiting(nextTransition: Date?)
    case waitingForPower(LockScreenPowerCondition)
    case waitingForPowerSource
    case sessionInactive
    case active(timeRange: String, idleMinutes: Int)
    case locking
    case locked
    case lockFailed
    case environmentFailed(reason: String)

    var text: String {
        switch self {
        case .disabled:
            "已关闭"
        case .restored:
            "已恢复系统原设置"
        case .systemSettingsChanged:
            "已修改系统锁屏设置"
        case .systemSettingsBlocked:
            "请先关闭时间策略再修改系统设置"
        case .noRules:
            "已开启，还没有时间规则"
        case .waiting(let nextTransition):
            if let nextTransition {
                "下一次执行：\(nextTransition.formatted(date: .omitted, time: .shortened))"
            } else {
                "已开启，等待下一个时间段"
            }
        case .waitingForPower(let condition):
            condition.waitingText
        case .waitingForPowerSource:
            "正在识别电源状态"
        case .sessionInactive:
            "用户会话未激活，已暂停"
        case .active(let timeRange, let idleMinutes):
            "正在执行：\(timeRange)，闲置 \(idleMinutes) 分钟后直接锁定"
        case .locking:
            "已达到闲置时间，正在直接锁定"
        case .locked:
            "已直接锁定"
        case .lockFailed:
            "系统未响应锁定请求，将自动重试"
        case .environmentFailed(let reason):
            reason
        }
    }

    var isEnvironmentFailure: Bool {
        if case .environmentFailed = self { return true }
        return false
    }
}

nonisolated struct LockScreenPolicy: Identifiable, Codable, Hashable, Sendable {
    static let maximumExtendedHour = 40
    static let maximumNameLength = 16

    var id: UUID
    var name: String
    var isEnabled: Bool
    var dayScope: LockScreenDayScope
    var customWeekdays: Set<Int>
    var powerCondition: LockScreenPowerCondition
    var startMinutes: Int
    var endMinutes: Int
    var idleMinutes: Int

    init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        dayScope: LockScreenDayScope = .everyDay,
        customWeekdays: Set<Int>? = nil,
        powerCondition: LockScreenPowerCondition = .any,
        startMinutes: Int = 9 * 60,
        endMinutes: Int = 18 * 60,
        idleMinutes: Int = 10
    ) {
        self.id = id
        self.name = Self.normalizedName(name)
        self.isEnabled = isEnabled
        self.dayScope = dayScope
        self.customWeekdays = Self.validWeekdays(customWeekdays ?? Self.defaultWeekdays(for: dayScope))
        self.powerCondition = powerCondition
        self.startMinutes = Self.clampedStartMinutes(startMinutes)
        self.endMinutes = Self.normalizedEndMinutes(endMinutes, relativeTo: self.startMinutes)
        self.idleMinutes = min(1_440, max(1, idleMinutes))
    }

    var crossesMidnight: Bool {
        effectiveEndMinutes > 24 * 60
    }

    var hasValidTimeRange: Bool {
        effectiveEndMinutes > startMinutes
    }

    var timeRangeText: String {
        "\(Self.clockText(startMinutes)) - \(Self.clockText(effectiveEndMinutes))"
    }

    func isActive(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard isEnabled, hasValidTimeRange else { return false }

        let startOfToday = calendar.startOfDay(for: date)
        for dayOffset in [-1, 0] {
            guard let policyDay = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                  applies(to: calendar.component(.weekday, from: policyDay)),
                  let policyStart = policyDate(on: policyDay, atExtendedMinutes: startMinutes, calendar: calendar),
                  let policyEnd = policyDate(on: policyDay, atExtendedMinutes: effectiveEndMinutes, calendar: calendar) else {
                continue
            }
            if date >= policyStart && date < policyEnd {
                return true
            }
        }
        return false
    }

    func transitionDates(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        guard isEnabled, hasValidTimeRange else { return [] }

        let startOfToday = calendar.startOfDay(for: date)
        var dates: [Date] = []
        for dayOffset in -1...8 {
            guard let startDate = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday),
                  applies(to: calendar.component(.weekday, from: startDate)),
                  let policyStart = policyDate(on: startDate, atExtendedMinutes: startMinutes, calendar: calendar) else {
                continue
            }

            guard let policyEnd = policyDate(
                on: startDate,
                atExtendedMinutes: effectiveEndMinutes,
                calendar: calendar
            ) else {
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

    static func minutes(from text: String, maximumHour: Int = 23) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...maximumHour).contains(hour),
              (0...59).contains(minute),
              maximumHour == 23 || hour < maximumHour || minute == 0 else {
            return nil
        }
        return hour * 60 + minute
    }

    static func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumNameLength))
    }

    mutating func toggleCustomWeekday(_ weekday: Int) {
        guard (1...7).contains(weekday) else { return }
        if customWeekdays.contains(weekday) {
            customWeekdays.remove(weekday)
        } else {
            customWeekdays.insert(weekday)
        }
    }

    mutating func setStartMinutes(_ value: Int) {
        startMinutes = Self.clampedStartMinutes(value)
        endMinutes = Self.normalizedEndMinutes(endMinutes, relativeTo: startMinutes)
    }

    mutating func setEndMinutes(_ value: Int) {
        endMinutes = Self.normalizedEndMinutes(value, relativeTo: startMinutes)
    }

    mutating func normalize() {
        name = Self.normalizedName(name)
        customWeekdays = Self.validWeekdays(customWeekdays)
        startMinutes = Self.clampedStartMinutes(startMinutes)
        endMinutes = Self.normalizedEndMinutes(endMinutes, relativeTo: startMinutes)
        idleMinutes = min(1_440, max(1, idleMinutes))
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

    private func policyDate(
        on policyDay: Date,
        atExtendedMinutes minutes: Int,
        calendar: Calendar
    ) -> Date? {
        let dayOffset = minutes / (24 * 60)
        let clockMinutes = minutes % (24 * 60)
        guard let localDay = calendar.date(byAdding: .day, value: dayOffset, to: policyDay) else {
            return nil
        }
        return calendar.date(
            bySettingHour: clockMinutes / 60,
            minute: clockMinutes % 60,
            second: 0,
            of: localDay,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, dayScope, customWeekdays, powerCondition, startMinutes, endMinutes, idleMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = Self.normalizedName(try container.decodeIfPresent(String.self, forKey: .name) ?? "")
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        dayScope = try container.decode(LockScreenDayScope.self, forKey: .dayScope)
        customWeekdays = Self.validWeekdays(
            try container.decodeIfPresent(Set<Int>.self, forKey: .customWeekdays)
                ?? Self.defaultWeekdays(for: dayScope)
        )
        powerCondition = try container.decodeIfPresent(LockScreenPowerCondition.self, forKey: .powerCondition) ?? .any
        startMinutes = Self.clampedStartMinutes(try container.decode(Int.self, forKey: .startMinutes))
        endMinutes = Self.normalizedEndMinutes(
            try container.decode(Int.self, forKey: .endMinutes),
            relativeTo: startMinutes
        )
        idleMinutes = min(1_440, max(1, try container.decode(Int.self, forKey: .idleMinutes)))
    }

    private static func clampedStartMinutes(_ value: Int) -> Int {
        min(23 * 60 + 59, max(0, value))
    }

    var effectiveEndMinutes: Int {
        let clamped = min(Self.maximumExtendedHour * 60, max(0, endMinutes))
        if clamped < startMinutes {
            return min(Self.maximumExtendedHour * 60, clamped + 24 * 60)
        }
        return clamped
    }

    private static func normalizedEndMinutes(_ value: Int, relativeTo startMinutes: Int) -> Int {
        let clamped = min(maximumExtendedHour * 60, max(0, value))
        guard clamped < startMinutes else { return clamped }
        return min(maximumExtendedHour * 60, clamped + 24 * 60)
    }
}

nonisolated struct LockScreenPolicyResolution: Equatable, Sendable {
    let timeActivePolicies: [LockScreenPolicy]
    let matchingPolicies: [LockScreenPolicy]
    let selectedPolicy: LockScreenPolicy?

    var waitingPolicy: LockScreenPolicy? {
        LockScreenPolicyResolver.preferredPolicy(from: timeActivePolicies)
    }
}

nonisolated enum LockScreenPolicyResolver {
    private struct WeeklyInterval {
        let lowerBound: Int
        let upperBound: Int

        func overlaps(_ other: WeeklyInterval) -> Bool {
            lowerBound < other.upperBound && other.lowerBound < upperBound
        }
    }

    private static let minutesPerDay = 24 * 60
    private static let minutesPerWeek = 7 * minutesPerDay

    static func resolve(
        policies: [LockScreenPolicy],
        at date: Date,
        powerSource: SystemPowerSourceState,
        calendar: Calendar = .autoupdatingCurrent
    ) -> LockScreenPolicyResolution {
        let timeActivePolicies = policies.filter { $0.isActive(at: date, calendar: calendar) }
        let matchingPolicies = timeActivePolicies.filter { $0.powerCondition.matches(powerSource) }
        return LockScreenPolicyResolution(
            timeActivePolicies: timeActivePolicies,
            matchingPolicies: matchingPolicies,
            selectedPolicy: preferredPolicy(from: matchingPolicies)
        )
    }

    static func conflictingPolicies(
        for policy: LockScreenPolicy,
        in policies: [LockScreenPolicy]
    ) -> [LockScreenPolicy] {
        policies
            .filter { $0.id != policy.id && policiesOverlap(policy, $0) }
            .sorted(by: policyComesBefore)
    }

    static func newlyConflictingPolicyIDs(
        for updatedPolicy: LockScreenPolicy,
        replacing originalPolicy: LockScreenPolicy,
        in policies: [LockScreenPolicy]
    ) -> Set<LockScreenPolicy.ID> {
        let originalConflicts = Set(
            conflictingPolicies(for: originalPolicy, in: policies).map(\.id)
        )
        var updatedPolicies = policies
        if let index = updatedPolicies.firstIndex(where: { $0.id == originalPolicy.id }) {
            updatedPolicies[index] = updatedPolicy
        } else {
            updatedPolicies.append(updatedPolicy)
        }
        let updatedConflicts = Set(
            conflictingPolicies(for: updatedPolicy, in: updatedPolicies).map(\.id)
        )
        return updatedConflicts.subtracting(originalConflicts)
    }

    static func policiesOverlap(_ lhs: LockScreenPolicy, _ rhs: LockScreenPolicy) -> Bool {
        guard lhs.isEnabled,
              rhs.isEnabled,
              lhs.hasValidTimeRange,
              rhs.hasValidTimeRange,
              lhs.powerCondition.overlaps(rhs.powerCondition) else {
            return false
        }

        let lhsIntervals = weeklyIntervals(for: lhs)
        let rhsIntervals = weeklyIntervals(for: rhs)
        return lhsIntervals.contains { lhsInterval in
            rhsIntervals.contains { lhsInterval.overlaps($0) }
        }
    }

    static func preferredPolicy(from policies: [LockScreenPolicy]) -> LockScreenPolicy? {
        policies.min(by: policyComesBefore)
    }

    nonisolated private static func policyComesBefore(
        _ lhs: LockScreenPolicy,
        _ rhs: LockScreenPolicy
    ) -> Bool {
        if lhs.idleMinutes != rhs.idleMinutes {
            return lhs.idleMinutes < rhs.idleMinutes
        }

        let lhsPowerSpecificity = lhs.powerCondition == .any ? 0 : 1
        let rhsPowerSpecificity = rhs.powerCondition == .any ? 0 : 1
        if lhsPowerSpecificity != rhsPowerSpecificity {
            return lhsPowerSpecificity > rhsPowerSpecificity
        }

        let lhsDuration = lhs.effectiveEndMinutes - lhs.startMinutes
        let rhsDuration = rhs.effectiveEndMinutes - rhs.startMinutes
        if lhsDuration != rhsDuration {
            return lhsDuration < rhsDuration
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func weeklyIntervals(for policy: LockScreenPolicy) -> [WeeklyInterval] {
        applicableWeekdays(for: policy).flatMap { weekday -> [WeeklyInterval] in
            let dayOffset = (weekday - 1) * minutesPerDay
            let lowerBound = dayOffset + policy.startMinutes
            let upperBound = dayOffset + policy.effectiveEndMinutes
            guard upperBound > lowerBound else { return [] }

            if upperBound <= minutesPerWeek {
                return [WeeklyInterval(lowerBound: lowerBound, upperBound: upperBound)]
            }
            return [
                WeeklyInterval(lowerBound: lowerBound, upperBound: minutesPerWeek),
                WeeklyInterval(lowerBound: 0, upperBound: upperBound - minutesPerWeek)
            ]
        }
    }

    private static func applicableWeekdays(for policy: LockScreenPolicy) -> Set<Int> {
        switch policy.dayScope {
        case .everyDay: Set(1...7)
        case .weekdays: Set(2...6)
        case .weekends: [1, 7]
        case .custom: policy.customWeekdays
        }
    }
}

nonisolated struct ScreenSaverLockBaseline: Codable, Equatable, Sendable {
    var idleTime: Int?
    var askForPassword: Bool?
    var askForPasswordDelay: Int?
}

extension ScreenSaverLockBaseline {
    var isEmpty: Bool {
        idleTime == nil && askForPassword == nil && askForPasswordDelay == nil
    }

    var idleMinutes: Int? {
        idleTime.map { max(0, Int((Double($0) / 60).rounded(.up))) }
    }

    var passwordDelayText: String {
        guard let askForPassword else { return "系统默认" }
        guard askForPassword else { return "不要求密码" }
        guard let askForPasswordDelay else { return "系统默认" }
        return askForPasswordDelay == 0 ? "立即" : "\(askForPasswordDelay) 秒后"
    }
}
