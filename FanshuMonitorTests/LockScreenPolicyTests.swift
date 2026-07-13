import Foundation
import Testing
@testable import FanshuMonitor

struct LockScreenPolicyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func everyDayPolicyMatchesWithinSameDayRange() {
        let policy = LockScreenPolicy(dayScope: .everyDay, startMinutes: 9 * 60, endMinutes: 18 * 60, idleMinutes: 10)

        #expect(policy.isActive(at: date(2026, 7, 13, 9, 0), calendar: calendar))
        #expect(policy.isActive(at: date(2026, 7, 13, 17, 59), calendar: calendar))
        #expect(!policy.isActive(at: date(2026, 7, 13, 18, 0), calendar: calendar))
    }

    @Test func overnightWeekdayPolicyUsesItsStartDay() {
        let policy = LockScreenPolicy(dayScope: .weekdays, startMinutes: 22 * 60, endMinutes: 6 * 60, idleMinutes: 5)

        // Tuesday 01:00 still belongs to the Monday overnight policy.
        #expect(policy.isActive(at: date(2026, 7, 14, 1, 0), calendar: calendar))
        // Monday 01:00 belongs to Sunday, which is not a weekday policy.
        #expect(!policy.isActive(at: date(2026, 7, 13, 1, 0), calendar: calendar))
    }

    @Test func policyRejectsEqualStartAndEndTimes() {
        let policy = LockScreenPolicy(startMinutes: 8 * 60, endMinutes: 8 * 60)

        #expect(!policy.hasValidTimeRange)
        #expect(!policy.isActive(at: date(2026, 7, 13, 8, 0), calendar: calendar))
    }

    @Test func policyAcceptsCustomIdleTime() {
        let policy = LockScreenPolicy(idleMinutes: 347)
        let cappedPolicy = LockScreenPolicy(idleMinutes: 9_999)

        #expect(policy.idleMinutes == 347)
        #expect(cappedPolicy.idleMinutes == 1_440)
    }

    @Test func customWeekdaysMatchOnlySelectedDays() {
        let policy = LockScreenPolicy(
            dayScope: .custom,
            customWeekdays: [2, 4, 6],
            startMinutes: 9 * 60,
            endMinutes: 18 * 60
        )

        #expect(policy.isActive(at: date(2026, 7, 13, 12, 0), calendar: calendar)) // Monday
        #expect(!policy.isActive(at: date(2026, 7, 14, 12, 0), calendar: calendar)) // Tuesday
        #expect(policy.isActive(at: date(2026, 7, 15, 12, 0), calendar: calendar)) // Wednesday
    }

    @Test func customTimeParserRequiresValidTwentyFourHourTime() {
        #expect(LockScreenPolicy.minutes(from: "00:00") == 0)
        #expect(LockScreenPolicy.minutes(from: "20:37") == 1_237)
        #expect(LockScreenPolicy.minutes(from: "24:00") == nil)
        #expect(LockScreenPolicy.minutes(from: "08:60") == nil)
        #expect(LockScreenPolicy.minutes(from: "8pm") == nil)
    }

    @Test func settingsPersistLockScreenPolicies() {
        let suite = "LockScreenPolicyTests.settingsPersistLockScreenPolicies"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)

        #expect(!settings.lockScreenPoliciesEnabled)
        settings.addLockScreenPolicy()
        settings.lockScreenPoliciesEnabled = true

        let loaded = MonitorSettings(defaults: defaults)
        #expect(loaded.lockScreenPoliciesEnabled)
        #expect(loaded.lockScreenPolicies.count == 1)
        #expect(loaded.lockScreenPolicies.first?.idleMinutes == 10)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }
}
