import Foundation
import Testing
@testable import FanshuMonitor

@MainActor
private final class LockAttemptProbe {
    var nativeRequests = 0
    var keyboardRequests = 0
    var isLocked = false
    var idleSeconds: TimeInterval = 0
    var screenSaverDisabled = false
    var screenSaverWriteSucceeds = true
    var assertionSucceeds = true
    var assertionAcquisitions = 0
    var assertionReleases = 0
    var restoreSucceeds = true
    var restoreRequests = 0
    var baseline = ScreenSaverLockBaseline(idleTime: 600, askForPassword: true, askForPasswordDelay: 0)
    var restoredBaseline: ScreenSaverLockBaseline?

    var environment: LockScreenSystemEnvironment {
        LockScreenSystemEnvironment(
            readSettings: {
                guard self.screenSaverDisabled else { return self.baseline }
                return ScreenSaverLockBaseline(
                    idleTime: 0,
                    askForPassword: self.baseline.askForPassword,
                    askForPasswordDelay: self.baseline.askForPasswordDelay
                )
            },
            applySettings: { _, _, _ in true },
            disableIdleScreenSaver: {
                guard self.screenSaverWriteSucceeds else { return false }
                self.screenSaverDisabled = true
                return true
            },
            isIdleScreenSaverDisabled: { self.screenSaverDisabled },
            restoreSettings: { baseline in
                self.restoreRequests += 1
                guard self.restoreSucceeds else { return false }
                self.restoredBaseline = baseline
                self.screenSaverDisabled = false
                return true
            },
            acquireDisplaySleepAssertion: {
                self.assertionAcquisitions += 1
                return self.assertionSucceeds
            },
            releaseDisplaySleepAssertion: {
                self.assertionReleases += 1
            }
        )
    }
}

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

    @Test func directLockScheduleWaitsOnlyForRemainingIdleTime() {
        #expect(DirectLockSchedule.remainingDelay(idleSeconds: 120, threshold: 300) == 180.25)
        #expect(DirectLockSchedule.remainingDelay(idleSeconds: 299.8, threshold: 300) == 1)
    }

    @Test func disabledScreenSaverIsRepresentedAsZeroMinutes() {
        let baseline = ScreenSaverLockBaseline(idleTime: 0, askForPassword: true, askForPasswordDelay: 0)

        #expect(baseline.idleMinutes == 0)
        #expect(!baseline.isEmpty)
    }

    @Test func sessionLockStateUsesTheSystemSessionFlag() {
        #expect(SystemSessionState.screenIsLocked(in: ["CGSSessionScreenIsLocked": true]))
        #expect(SystemSessionState.screenIsLocked(in: ["CGSSessionScreenIsLocked": NSNumber(value: 1)]))
        #expect(!SystemSessionState.screenIsLocked(in: ["CGSSessionScreenIsLocked": false]))
        #expect(!SystemSessionState.screenIsLocked(in: nil))
    }

    @Test @MainActor func nativeLockConfirmationSkipsKeyboardFallback() async {
        let probe = LockAttemptProbe()
        let result = await LockScreenAttemptRunner.run(
            timing: testAttemptTiming,
            requestNativeLock: {
                probe.nativeRequests += 1
                probe.isLocked = true
                return true
            },
            requestKeyboardLock: {
                probe.keyboardRequests += 1
                return true
            },
            isScreenLocked: { probe.isLocked }
        )

        #expect(result == .locked)
        #expect(probe.nativeRequests == 1)
        #expect(probe.keyboardRequests == 0)
    }

    @Test @MainActor func unconfirmedNativeLockUsesKeyboardFallback() async {
        let probe = LockAttemptProbe()
        let result = await LockScreenAttemptRunner.run(
            timing: testAttemptTiming,
            requestNativeLock: {
                probe.nativeRequests += 1
                return true
            },
            requestKeyboardLock: {
                probe.keyboardRequests += 1
                probe.isLocked = true
                return true
            },
            isScreenLocked: { probe.isLocked }
        )

        #expect(result == .locked)
        #expect(probe.nativeRequests == 1)
        #expect(probe.keyboardRequests == 1)
    }

    @Test @MainActor func unavailableLockMethodsFailWithoutFalseConfirmation() async {
        let probe = LockAttemptProbe()
        let result = await LockScreenAttemptRunner.run(
            timing: testAttemptTiming,
            requestNativeLock: {
                probe.nativeRequests += 1
                return false
            },
            requestKeyboardLock: {
                probe.keyboardRequests += 1
                return false
            },
            isScreenLocked: { probe.isLocked }
        )

        #expect(result == .failed)
        #expect(probe.nativeRequests == 1)
        #expect(probe.keyboardRequests == 1)
    }

    @Test @MainActor func cancellingLockAttemptPreventsDelayedKeyboardFallback() async {
        let probe = LockAttemptProbe()
        let task = Task { @MainActor in
            await LockScreenAttemptRunner.run(
                timing: LockScreenAttemptTiming(
                    pollInterval: .milliseconds(50),
                    maximumPollCount: 10,
                    keyboardFallbackPoll: 5,
                    retryDelay: 1
                ),
                requestNativeLock: {
                    probe.nativeRequests += 1
                    return true
                },
                requestKeyboardLock: {
                    probe.keyboardRequests += 1
                    return true
                },
                isScreenLocked: { probe.isLocked }
            )
        }

        await Task.yield()
        task.cancel()
        let result = await task.value

        #expect(result == .cancelled)
        #expect(probe.nativeRequests == 1)
        #expect(probe.keyboardRequests == 0)
    }

    @Test @MainActor func disablingPolicyImmediatelyCancelsPendingFallback() async {
        let probe = LockAttemptProbe()
        probe.idleSeconds = 120
        let settings = activeSettings(suite: "LockScreenPolicyTests.disablingPolicyImmediatelyCancelsPendingFallback")
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { probe.idleSeconds },
            requestNativeLock: {
                probe.nativeRequests += 1
                return true
            },
            requestKeyboardLock: {
                probe.keyboardRequests += 1
                return true
            },
            screenLockedProvider: { probe.isLocked },
            attemptTiming: LockScreenAttemptTiming(
                pollInterval: .milliseconds(20),
                maximumPollCount: 20,
                keyboardFallbackPoll: 5,
                retryDelay: 1
            ),
            environment: probe.environment
        )

        controller.configure(settings: settings)
        try? await Task.sleep(for: .milliseconds(30))
        settings.setLockScreenPoliciesEnabled(false)
        try? await Task.sleep(for: .milliseconds(150))

        #expect(probe.nativeRequests == 1)
        #expect(probe.keyboardRequests == 0)
        #expect(controller.status == .disabled)
    }

    @Test @MainActor func wakeAndSessionActivationShareOneDelayedRecovery() async {
        let probe = LockAttemptProbe()
        let settings = activeSettings(suite: "LockScreenPolicyTests.wakeAndSessionActivationShareOneDelayedRecovery")
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { probe.idleSeconds },
            requestNativeLock: {
                probe.nativeRequests += 1
                probe.isLocked = true
                return true
            },
            requestKeyboardLock: { false },
            screenLockedProvider: { probe.isLocked },
            attemptTiming: testAttemptTiming,
            recoveryDelay: .milliseconds(30),
            environment: probe.environment
        )

        controller.configure(settings: settings)
        controller.handleSystemWillSleep()
        probe.idleSeconds = 120
        controller.handleSessionDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(probe.nativeRequests == 0)

        controller.handleSystemDidWake()
        try? await Task.sleep(for: .milliseconds(10))
        #expect(probe.nativeRequests == 0)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(probe.nativeRequests == 1)
        #expect(controller.status == .locked)
    }

    @Test @MainActor func everyLoginResumesPolicyAndAllowsTheNextLock() async {
        let probe = LockAttemptProbe()
        probe.idleSeconds = 120
        let settings = activeSettings(suite: "LockScreenPolicyTests.everyLoginResumesPolicyAndAllowsTheNextLock")
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { probe.idleSeconds },
            requestNativeLock: {
                probe.nativeRequests += 1
                probe.isLocked = true
                return true
            },
            requestKeyboardLock: { false },
            screenLockedProvider: { probe.isLocked },
            attemptTiming: testAttemptTiming,
            environment: probe.environment
        )

        controller.configure(settings: settings)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.status == .locked)
        #expect(probe.nativeRequests == 1)

        probe.isLocked = false
        probe.idleSeconds = 0
        controller.handleSessionDidBecomeActive()
        #expect(controller.status == .active(timeRange: "00:00 - 40:00", idleMinutes: 1))

        probe.idleSeconds = 120
        controller.reevaluate()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.status == .locked)
        #expect(probe.nativeRequests == 2)
    }

    @Test @MainActor func watchdogRecoversWhenUnlockNotificationIsMissed() async {
        let probe = LockAttemptProbe()
        probe.idleSeconds = 120
        let settings = activeSettings(suite: "LockScreenPolicyTests.watchdogRecoversWhenUnlockNotificationIsMissed")
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { probe.idleSeconds },
            requestNativeLock: {
                probe.nativeRequests += 1
                probe.isLocked = true
                return true
            },
            requestKeyboardLock: { false },
            screenLockedProvider: { probe.isLocked },
            attemptTiming: testAttemptTiming,
            environment: probe.environment
        )

        controller.configure(settings: settings)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.status == .locked)

        probe.isLocked = false
        probe.idleSeconds = 0
        controller.reconcileSessionState()

        #expect(controller.status == .active(timeRange: "00:00 - 40:00", idleMinutes: 1))
        #expect(probe.assertionAcquisitions >= 2)
    }

    @Test @MainActor func environmentFailureIsVisibleAndTerminationRestoresBaseline() {
        let probe = LockAttemptProbe()
        probe.screenSaverWriteSucceeds = false
        probe.assertionSucceeds = false
        let settings = activeSettings(suite: "LockScreenPolicyTests.environmentFailureIsVisibleAndTerminationRestoresBaseline")
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { 0 },
            requestNativeLock: { false },
            requestKeyboardLock: { false },
            screenLockedProvider: { false },
            environment: probe.environment
        )

        controller.configure(settings: settings)
        #expect(controller.status.isEnvironmentFailure)

        controller.prepareForTermination()
        #expect(probe.restoreRequests == 1)
        #expect(probe.assertionReleases > 0)
    }

    @Test @MainActor func emptySystemBaselineSurvivesReevaluationAndRestoresExactly() {
        let probe = LockAttemptProbe()
        probe.baseline = ScreenSaverLockBaseline(
            idleTime: nil,
            askForPassword: nil,
            askForPasswordDelay: nil
        )
        let settings = activeSettings(suite: "LockScreenPolicyTests.emptySystemBaselineSurvivesReevaluationAndRestoresExactly")
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { 0 },
            requestNativeLock: { false },
            requestKeyboardLock: { false },
            screenLockedProvider: { false },
            environment: probe.environment
        )

        controller.configure(settings: settings)
        #expect(settings.lockScreenBaseline == probe.baseline)
        #expect(probe.screenSaverDisabled)

        controller.reevaluate()
        #expect(settings.lockScreenBaseline == probe.baseline)

        settings.setLockScreenPoliciesEnabled(false)
        #expect(probe.restoredBaseline == probe.baseline)
        #expect(!probe.screenSaverDisabled)
        #expect(settings.lockScreenBaseline == nil)
    }

    @Test func lockScreenStatusReflectsCurrentPhase() {
        #expect(LockScreenPolicyStatus.disabled.text == "已关闭")
        #expect(
            LockScreenPolicyStatus.active(timeRange: "00:00 - 07:00", idleMinutes: 5).text
                == "正在执行：00:00 - 07:00，闲置 5 分钟后直接锁定"
        )
        #expect(LockScreenPolicyStatus.locking.text == "已达到闲置时间，正在直接锁定")
        #expect(LockScreenPolicyStatus.lockFailed.text == "系统未响应锁定请求，将自动重试")
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

    @Test func customTimeParserSupportsExtendedEndTimes() {
        #expect(LockScreenPolicy.minutes(from: "00:00") == 0)
        #expect(LockScreenPolicy.minutes(from: "24:00") == nil)
        #expect(LockScreenPolicy.minutes(from: "24:00", maximumHour: 40) == 1_440)
        #expect(LockScreenPolicy.minutes(from: "25:00", maximumHour: 40) == 1_500)
        #expect(LockScreenPolicy.minutes(from: "39:59", maximumHour: 40) == 2_399)
        #expect(LockScreenPolicy.minutes(from: "40:00", maximumHour: 40) == 2_400)
        #expect(LockScreenPolicy.minutes(from: "20:37") == 1_237)
        #expect(LockScreenPolicy.minutes(from: "23:59") == 1_439)
        #expect(LockScreenPolicy.minutes(from: "40:01", maximumHour: 40) == nil)
        #expect(LockScreenPolicy.minutes(from: "08:60") == nil)
        #expect(LockScreenPolicy.minutes(from: "8pm") == nil)
    }

    @Test func extendedEndTimeMapsToTheFollowingDay() {
        let policy = LockScreenPolicy(startMinutes: 20 * 60, endMinutes: 25 * 60, idleMinutes: 20)

        #expect(policy.timeRangeText == "20:00 - 25:00")
        #expect(policy.isActive(at: date(2026, 7, 13, 23, 0), calendar: calendar))
        #expect(policy.isActive(at: date(2026, 7, 14, 0, 59), calendar: calendar))
        #expect(!policy.isActive(at: date(2026, 7, 14, 1, 0), calendar: calendar))
    }

    @Test func extendedPolicyKeepsItsStartDayScope() {
        let policy = LockScreenPolicy(
            dayScope: .custom,
            customWeekdays: [2],
            startMinutes: 0,
            endMinutes: 40 * 60,
            idleMinutes: 20
        )

        #expect(policy.isActive(at: date(2026, 7, 13, 0, 0), calendar: calendar))
        #expect(policy.isActive(at: date(2026, 7, 14, 15, 59), calendar: calendar))
        #expect(!policy.isActive(at: date(2026, 7, 14, 16, 0), calendar: calendar))
    }

    @Test func overnightNormalizationNeverExceedsFortyHours() {
        let policy = LockScreenPolicy(startMinutes: 23 * 60, endMinutes: 18 * 60)

        #expect(policy.endMinutes == 40 * 60)
        #expect(policy.timeRangeText == "23:00 - 40:00")
    }

    @Test func endOfDayTimeKeepsSameDayScheduleActiveUntilMidnight() {
        let policy = LockScreenPolicy(startMinutes: 12 * 60, endMinutes: 24 * 60, idleMinutes: 5)

        #expect(policy.timeRangeText == "12:00 - 24:00")
        #expect(policy.isActive(at: date(2026, 7, 13, 23, 59), calendar: calendar))
        #expect(!policy.isActive(at: date(2026, 7, 14, 0, 0), calendar: calendar))
    }

    @Test @MainActor func legacyPolicyDataDecodesWithoutCustomWeekdays() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","isEnabled":true,"dayScope":"weekdays","startMinutes":720,"endMinutes":1440,"idleMinutes":15}
        """

        let policy = try JSONDecoder().decode(LockScreenPolicy.self, from: Data(json.utf8))
        #expect(policy.customWeekdays == Set(2...6))
        #expect(policy.endMinutes == 1_440)
    }

    @Test @MainActor func legacyOvernightPolicyMigratesToExtendedTime() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","isEnabled":true,"dayScope":"everyDay","startMinutes":1320,"endMinutes":360,"idleMinutes":20}
        """

        let policy = try JSONDecoder().decode(LockScreenPolicy.self, from: Data(json.utf8))
        #expect(policy.endMinutes == 30 * 60)
        #expect(policy.timeRangeText == "22:00 - 30:00")
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

    @Test func masterLockScreenSwitchEnablesExistingRules() {
        let suite = "LockScreenPolicyTests.masterLockScreenSwitchEnablesExistingRules"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()

        var disabledPolicy = settings.lockScreenPolicies[0]
        disabledPolicy.isEnabled = false
        settings.updateLockScreenPolicy(disabledPolicy)
        settings.setLockScreenPoliciesEnabled(true)

        #expect(settings.lockScreenPoliciesEnabled)
        #expect(settings.lockScreenPolicies.filter { !$0.isEnabled }.isEmpty)
    }

    @Test func fieldUpdatesAlwaysMutateTheLatestStoredPolicy() {
        let suite = "LockScreenPolicyTests.fieldUpdatesAlwaysMutateTheLatestStoredPolicy"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()
        let id = settings.lockScreenPolicies[0].id

        settings.updateLockScreenPolicy(id: id) { $0.startMinutes = 20 * 60 }
        settings.updateLockScreenPolicy(id: id) { $0.endMinutes = 24 * 60 }
        settings.updateLockScreenPolicy(id: id) { $0.idleMinutes = 37 }

        let policy = settings.lockScreenPolicies[0]
        #expect(policy.startMinutes == 20 * 60)
        #expect(policy.endMinutes == 24 * 60)
        #expect(policy.idleMinutes == 37)
    }

    @Test func addedPolicyContinuesThroughEndOfDay() {
        let suite = "LockScreenPolicyTests.addedPolicyContinuesThroughEndOfDay"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()
        let firstID = settings.lockScreenPolicies[0].id
        settings.updateLockScreenPolicy(id: firstID) {
            $0.startMinutes = 0
            $0.endMinutes = 7 * 60
        }

        settings.addLockScreenPolicy()

        #expect(settings.lockScreenPolicies[1].startMinutes == 7 * 60)
        #expect(settings.lockScreenPolicies[1].endMinutes == 24 * 60)
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

    private var testAttemptTiming: LockScreenAttemptTiming {
        LockScreenAttemptTiming(
            pollInterval: .milliseconds(1),
            maximumPollCount: 4,
            keyboardFallbackPoll: 1,
            retryDelay: 1
        )
    }

    @MainActor
    private func activeSettings(suite: String) -> MonitorSettings {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()
        let id = settings.lockScreenPolicies[0].id
        settings.updateLockScreenPolicy(id: id) {
            $0.startMinutes = 0
            $0.endMinutes = 40 * 60
            $0.idleMinutes = 1
        }
        settings.setLockScreenPoliciesEnabled(true)
        return settings
    }
}
