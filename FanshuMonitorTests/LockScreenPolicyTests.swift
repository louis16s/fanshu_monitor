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
    var fallbackIdleSeconds: Int?
    var screenSaverWriteSucceeds = true
    var assertionSucceeds = true
    var assertionAcquisitions = 0
    var assertionReleases = 0
    var restoreSucceeds = true
    var restoreRequests = 0
    var baseline = ScreenSaverLockBaseline(idleTime: 600, askForPassword: true, askForPasswordDelay: 0)
    var restoredBaseline: ScreenSaverLockBaseline?
    var powerSourceState = SystemPowerSourceState.connected

    var environment: LockScreenSystemEnvironment {
        LockScreenSystemEnvironment(
            readSettings: {
                guard self.screenSaverDisabled else { return self.baseline }
                return ScreenSaverLockBaseline(
                    idleTime: self.fallbackIdleSeconds,
                    askForPassword: true,
                    askForPasswordDelay: 0
                )
            },
            applySettings: { _, _, _ in true },
            prepareIdleLockFallback: { idleSeconds in
                guard self.screenSaverWriteSucceeds else { return false }
                self.screenSaverDisabled = true
                self.fallbackIdleSeconds = idleSeconds
                return true
            },
            idleLockFallbackMatches: { idleSeconds in
                self.screenSaverDisabled && self.fallbackIdleSeconds == idleSeconds
            },
            restoreSettings: { baseline in
                self.restoreRequests += 1
                guard self.restoreSucceeds else { return false }
                self.restoredBaseline = baseline
                self.screenSaverDisabled = false
                self.fallbackIdleSeconds = nil
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

    @Test func lockScreenPowerConditionsMatchOnlyTheirSelectedSource() {
        #expect(LockScreenPowerCondition.any.matches(.unknown))
        #expect(LockScreenPowerCondition.connected.matches(.connected))
        #expect(!LockScreenPowerCondition.connected.matches(.battery))
        #expect(LockScreenPowerCondition.battery.matches(.battery))
        #expect(!LockScreenPowerCondition.battery.matches(.unknown))
    }

    @Test func resolverUsesTheStrictestMatchingPolicyInsteadOfArrayOrder() {
        let day = LockScreenPolicy(
            name: "白天",
            powerCondition: .battery,
            startMinutes: 7 * 60,
            endMinutes: 24 * 60,
            idleMinutes: 20
        )
        let strictDay = LockScreenPolicy(
            name: "时间段 1",
            powerCondition: .battery,
            startMinutes: 7 * 60,
            endMinutes: 24 * 60,
            idleMinutes: 5
        )
        let now = date(2026, 7, 13, 12, 0)

        let forward = LockScreenPolicyResolver.resolve(
            policies: [day, strictDay],
            at: now,
            powerSource: .battery,
            calendar: calendar
        )
        let reversed = LockScreenPolicyResolver.resolve(
            policies: [strictDay, day],
            at: now,
            powerSource: .battery,
            calendar: calendar
        )

        #expect(forward.selectedPolicy?.id == strictDay.id)
        #expect(reversed.selectedPolicy?.id == strictDay.id)
        #expect(forward.matchingPolicies.count == 2)
    }

    @Test func conflictDetectionMatchesScheduleAndPowerIntersections() {
        let night = LockScreenPolicy(
            name: "夜间",
            powerCondition: .any,
            startMinutes: 0,
            endMinutes: 7 * 60,
            idleMinutes: 5
        )
        let day = LockScreenPolicy(
            name: "白天",
            powerCondition: .battery,
            startMinutes: 7 * 60,
            endMinutes: 24 * 60,
            idleMinutes: 20
        )
        let duplicateDay = LockScreenPolicy(
            name: "时间段 1",
            powerCondition: .battery,
            startMinutes: 7 * 60,
            endMinutes: 24 * 60,
            idleMinutes: 5
        )
        let connectedDay = LockScreenPolicy(
            name: "接电白天",
            powerCondition: .connected,
            startMinutes: 7 * 60,
            endMinutes: 24 * 60,
            idleMinutes: 5
        )

        #expect(!LockScreenPolicyResolver.policiesOverlap(night, day))
        #expect(LockScreenPolicyResolver.policiesOverlap(day, duplicateDay))
        #expect(!LockScreenPolicyResolver.policiesOverlap(day, connectedDay))
        #expect(
            LockScreenPolicyResolver.conflictingPolicies(
                for: day,
                in: [night, day, duplicateDay, connectedDay]
            ).map(\.id) == [duplicateDay.id]
        )
    }

    @Test func conflictDetectionHandlesCrossMidnightAndWeekBoundary() {
        let saturdayNight = LockScreenPolicy(
            dayScope: .custom,
            customWeekdays: [7],
            powerCondition: .any,
            startMinutes: 23 * 60,
            endMinutes: 25 * 60,
            idleMinutes: 5
        )
        let sundayMorning = LockScreenPolicy(
            dayScope: .custom,
            customWeekdays: [1],
            powerCondition: .battery,
            startMinutes: 30,
            endMinutes: 2 * 60,
            idleMinutes: 10
        )
        let mondayMorning = LockScreenPolicy(
            dayScope: .custom,
            customWeekdays: [2],
            powerCondition: .battery,
            startMinutes: 30,
            endMinutes: 2 * 60,
            idleMinutes: 10
        )

        #expect(LockScreenPolicyResolver.policiesOverlap(saturdayNight, sundayMorning))
        #expect(!LockScreenPolicyResolver.policiesOverlap(saturdayNight, mondayMorning))
    }

    @Test func newlyIntroducedConflictsOnlyReportAddedRelationships() {
        let morning = LockScreenPolicy(
            name: "上午",
            powerCondition: .battery,
            startMinutes: 8 * 60,
            endMinutes: 12 * 60,
            idleMinutes: 10
        )
        let afternoon = LockScreenPolicy(
            name: "下午",
            powerCondition: .battery,
            startMinutes: 13 * 60,
            endMinutes: 18 * 60,
            idleMinutes: 10
        )
        var overlappingAfternoon = afternoon
        overlappingAfternoon.setStartMinutes(11 * 60)

        let introduced = LockScreenPolicyResolver.newlyConflictingPolicyIDs(
            for: overlappingAfternoon,
            replacing: afternoon,
            in: [morning, afternoon]
        )
        #expect(introduced == [morning.id])

        var stillOverlapping = overlappingAfternoon
        stillOverlapping.setStartMinutes(10 * 60)
        let existing = LockScreenPolicyResolver.newlyConflictingPolicyIDs(
            for: stillOverlapping,
            replacing: overlappingAfternoon,
            in: [morning, overlappingAfternoon]
        )
        #expect(existing.isEmpty)

        var connectedAfternoon = overlappingAfternoon
        connectedAfternoon.powerCondition = .connected
        let removed = LockScreenPolicyResolver.newlyConflictingPolicyIDs(
            for: connectedAfternoon,
            replacing: overlappingAfternoon,
            in: [morning, overlappingAfternoon]
        )
        #expect(removed.isEmpty)
    }

    @Test func screenshotPoliciesHaveDeterministicBoundariesAndPriority() {
        let night = LockScreenPolicy(
            name: "夜间",
            powerCondition: .any,
            startMinutes: 0,
            endMinutes: 7 * 60,
            idleMinutes: 5
        )
        let day = LockScreenPolicy(
            name: "白天",
            powerCondition: .battery,
            startMinutes: 7 * 60,
            endMinutes: 24 * 60,
            idleMinutes: 20
        )
        let strictDay = LockScreenPolicy(
            name: "时间段 1",
            powerCondition: .battery,
            startMinutes: 7 * 60,
            endMinutes: 24 * 60,
            idleMinutes: 5
        )
        let policies = [night, day, strictDay]

        let beforeBoundary = LockScreenPolicyResolver.resolve(
            policies: policies,
            at: date(2026, 7, 13, 6, 59),
            powerSource: .connected,
            calendar: calendar
        )
        let batteryDay = LockScreenPolicyResolver.resolve(
            policies: policies,
            at: date(2026, 7, 13, 7, 0),
            powerSource: .battery,
            calendar: calendar
        )
        let connectedDay = LockScreenPolicyResolver.resolve(
            policies: policies,
            at: date(2026, 7, 13, 7, 0),
            powerSource: .connected,
            calendar: calendar
        )
        let beforeMidnight = LockScreenPolicyResolver.resolve(
            policies: policies,
            at: date(2026, 7, 13, 23, 59),
            powerSource: .battery,
            calendar: calendar
        )
        let atMidnight = LockScreenPolicyResolver.resolve(
            policies: policies,
            at: date(2026, 7, 14, 0, 0),
            powerSource: .battery,
            calendar: calendar
        )

        #expect(beforeBoundary.selectedPolicy?.id == night.id)
        #expect(batteryDay.selectedPolicy?.id == strictDay.id)
        #expect(connectedDay.selectedPolicy == nil)
        #expect(beforeMidnight.selectedPolicy?.id == strictDay.id)
        #expect(atMidnight.selectedPolicy?.id == night.id)
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

    @Test @MainActor func manualLockUsesTheConfirmedDirectLockPath() async {
        let probe = LockAttemptProbe()
        let controller = LockScreenPolicyController(
            requestNativeLock: {
                probe.nativeRequests += 1
                probe.isLocked = true
                return true
            },
            requestKeyboardLock: {
                probe.keyboardRequests += 1
                return true
            },
            screenLockedProvider: { probe.isLocked },
            attemptTiming: testAttemptTiming,
            environment: probe.environment
        )

        controller.lockNow()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(probe.nativeRequests == 1)
        #expect(probe.keyboardRequests == 0)
        #expect(controller.status == .locked)
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
        #expect(probe.fallbackIdleSeconds == 120)

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
        #expect(LockScreenPolicyStatus.waitingForPower(.connected).text == "等待接通电源")
    }

    @Test @MainActor func controllerReevaluatesPolicyAgainstPowerSource() {
        let probe = LockAttemptProbe()
        let settings = activeSettings(suite: "LockScreenPolicyTests.controllerReevaluatesPolicyAgainstPowerSource")
        let id = settings.lockScreenPolicies[0].id
        settings.updateLockScreenPolicy(id: id) { $0.powerCondition = .connected }
        probe.powerSourceState = .battery
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { 0 },
            requestNativeLock: { false },
            requestKeyboardLock: { false },
            screenLockedProvider: { false },
            powerSourceProvider: { probe.powerSourceState },
            environment: probe.environment
        )

        controller.configure(settings: settings)
        #expect(controller.activePolicy == nil)
        #expect(controller.status == .waitingForPower(.connected))

        probe.powerSourceState = .connected
        controller.reevaluate()
        #expect(controller.activePolicy?.id == id)
    }

    @Test @MainActor func unknownPowerSourceHasAnExplicitWaitingState() {
        let probe = LockAttemptProbe()
        let settings = activeSettings(suite: "LockScreenPolicyTests.unknownPowerSourceHasAnExplicitWaitingState")
        let id = settings.lockScreenPolicies[0].id
        settings.updateLockScreenPolicy(id: id) { $0.powerCondition = .battery }
        probe.powerSourceState = .unknown
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { 0 },
            requestNativeLock: { false },
            requestKeyboardLock: { false },
            screenLockedProvider: { false },
            powerSourceProvider: { probe.powerSourceState },
            environment: probe.environment
        )

        controller.configure(settings: settings)

        #expect(controller.activePolicy == nil)
        #expect(controller.status == .waitingForPowerSource)
    }

    @Test @MainActor func sleepPausesEveryReevaluationUntilWakeRecovery() async {
        let probe = LockAttemptProbe()
        let settings = activeSettings(suite: "LockScreenPolicyTests.sleepPausesEveryReevaluationUntilWakeRecovery")
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { probe.idleSeconds },
            requestNativeLock: {
                probe.nativeRequests += 1
                return true
            },
            requestKeyboardLock: { false },
            screenLockedProvider: { false },
            powerSourceProvider: { probe.powerSourceState },
            recoveryDelay: .milliseconds(30),
            environment: probe.environment
        )

        controller.configure(settings: settings)
        let acquisitionsBeforeSleep = probe.assertionAcquisitions
        controller.handleSystemWillSleep()
        probe.idleSeconds = 120
        controller.reevaluate()
        settings.updateLockScreenPolicy(id: settings.lockScreenPolicies[0].id) {
            $0.idleMinutes = 2
        }
        try? await Task.sleep(for: .milliseconds(150))

        #expect(probe.assertionAcquisitions == acquisitionsBeforeSleep)
        #expect(probe.nativeRequests == 0)

        controller.handleSystemDidWake()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(probe.assertionAcquisitions > acquisitionsBeforeSleep)
        #expect(probe.nativeRequests == 1)
    }

    @Test @MainActor func waitingPeriodClearsBaselineAndRecapturesExternalChanges() {
        let probe = LockAttemptProbe()
        let settings = activeSettings(
            suite: "LockScreenPolicyTests.waitingPeriodClearsBaselineAndRecapturesExternalChanges"
        )
        let id = settings.lockScreenPolicies[0].id
        settings.updateLockScreenPolicy(id: id) { $0.powerCondition = .connected }
        probe.powerSourceState = .connected
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { 0 },
            requestNativeLock: { false },
            requestKeyboardLock: { false },
            screenLockedProvider: { false },
            powerSourceProvider: { probe.powerSourceState },
            environment: probe.environment
        )

        controller.configure(settings: settings)
        #expect(settings.lockScreenBaseline == probe.baseline)

        probe.powerSourceState = .battery
        controller.reevaluate()
        #expect(settings.lockScreenBaseline == nil)

        let externallyChangedBaseline = ScreenSaverLockBaseline(
            idleTime: 1_200,
            askForPassword: true,
            askForPasswordDelay: 30
        )
        probe.baseline = externallyChangedBaseline
        probe.powerSourceState = .connected
        controller.reevaluate()
        #expect(settings.lockScreenBaseline == externallyChangedBaseline)

        settings.setLockScreenPoliciesEnabled(false)
        #expect(probe.restoredBaseline == externallyChangedBaseline)
    }

    @Test @MainActor func failedBaselineRestoreRetriesWithoutNormalPolling() async {
        let probe = LockAttemptProbe()
        let settings = activeSettings(
            suite: "LockScreenPolicyTests.failedBaselineRestoreRetriesWithoutNormalPolling"
        )
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { 0 },
            requestNativeLock: { false },
            requestKeyboardLock: { false },
            screenLockedProvider: { false },
            baselineRestoreRetryInterval: 0.02,
            environment: probe.environment
        )

        controller.configure(settings: settings)
        probe.restoreSucceeds = false
        settings.setLockScreenPoliciesEnabled(false)
        #expect(controller.status.isEnvironmentFailure)
        #expect(settings.lockScreenBaseline != nil)

        probe.restoreSucceeds = true
        let deadline = ContinuousClock.now + .seconds(1)
        while controller.status != .disabled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(controller.status == .disabled)
        #expect(settings.lockScreenBaseline == nil)
        #expect(probe.restoreRequests >= 2)
    }

    @Test @MainActor func inactiveUnlockedSessionIsPausedInsteadOfReportedAsLocked() {
        let probe = LockAttemptProbe()
        let settings = activeSettings(
            suite: "LockScreenPolicyTests.inactiveUnlockedSessionIsPausedInsteadOfReportedAsLocked"
        )
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { 0 },
            requestNativeLock: { false },
            requestKeyboardLock: { false },
            screenLockedProvider: { probe.isLocked },
            environment: probe.environment
        )

        controller.configure(settings: settings)
        probe.isLocked = false
        controller.handleSessionDidResignActive()
        #expect(controller.status == .sessionInactive)
        let acquisitionsWhileInactive = probe.assertionAcquisitions
        controller.reevaluate()
        #expect(controller.status == .sessionInactive)
        #expect(probe.assertionAcquisitions == acquisitionsWhileInactive)

        probe.isLocked = true
        controller.handleScreenDidLock()
        #expect(controller.status == .locked)
    }

    @Test @MainActor func powerChangeCancelsAnObsoleteLockAttempt() async {
        let probe = LockAttemptProbe()
        probe.idleSeconds = 120
        probe.powerSourceState = .connected
        let suite = "LockScreenPolicyTests.powerChangeCancelsAnObsoleteLockAttempt"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()
        let connectedID = settings.lockScreenPolicies[0].id
        settings.updateLockScreenPolicy(id: connectedID) {
            $0.startMinutes = 0
            $0.endMinutes = 40 * 60
            $0.idleMinutes = 1
            $0.powerCondition = .connected
        }
        settings.addLockScreenPolicy()
        let batteryID = settings.lockScreenPolicies[1].id
        settings.updateLockScreenPolicy(id: batteryID) {
            $0.startMinutes = 0
            $0.endMinutes = 40 * 60
            $0.idleMinutes = 20
            $0.powerCondition = .battery
        }
        settings.setLockScreenPoliciesEnabled(true)
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
            screenLockedProvider: { false },
            powerSourceProvider: { probe.powerSourceState },
            attemptTiming: LockScreenAttemptTiming(
                pollInterval: .milliseconds(10),
                maximumPollCount: 20,
                keyboardFallbackPoll: 2,
                retryDelay: 1
            ),
            environment: probe.environment
        )

        controller.configure(settings: settings)
        try? await Task.sleep(for: .milliseconds(5))
        probe.powerSourceState = .battery
        controller.reevaluate()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(probe.nativeRequests == 1)
        #expect(probe.keyboardRequests == 0)
        #expect(controller.activePolicy?.id == batteryID)
        #expect(controller.status == .active(timeRange: "00:00 - 40:00", idleMinutes: 20))
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

    @Test func endOfDayUsesLocalMidnightAcrossDaylightSavingTime() {
        var newYorkCalendar = Calendar(identifier: .gregorian)
        newYorkCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let policy = LockScreenPolicy(
            dayScope: .custom,
            customWeekdays: [1],
            startMinutes: 0,
            endMinutes: 24 * 60,
            idleMinutes: 5
        )

        #expect(policy.isActive(
            at: date(2026, 3, 8, 23, 59, calendar: newYorkCalendar),
            calendar: newYorkCalendar
        ))
        #expect(!policy.isActive(
            at: date(2026, 3, 9, 0, 0, calendar: newYorkCalendar),
            calendar: newYorkCalendar
        ))
    }

    @Test @MainActor func legacyPolicyDataDecodesWithoutCustomWeekdays() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","isEnabled":true,"dayScope":"weekdays","startMinutes":720,"endMinutes":1440,"idleMinutes":15}
        """

        let policy = try JSONDecoder().decode(LockScreenPolicy.self, from: Data(json.utf8))
        #expect(policy.name.isEmpty)
        #expect(policy.customWeekdays == Set(2...6))
        #expect(policy.powerCondition == .any)
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
        let id = settings.lockScreenPolicies[0].id
        settings.updateLockScreenPolicy(id: id) {
            $0.name = "深夜专注"
            $0.powerCondition = .connected
        }
        settings.lockScreenPoliciesEnabled = true

        let loaded = MonitorSettings(defaults: defaults)
        #expect(loaded.lockScreenPoliciesEnabled)
        #expect(loaded.lockScreenPolicies.count == 1)
        #expect(loaded.lockScreenPolicies.first?.name == "深夜专注")
        #expect(loaded.lockScreenPolicies.first?.powerCondition == .connected)
        #expect(loaded.lockScreenPolicies.first?.idleMinutes == 10)
    }

    @Test func masterLockScreenSwitchPreservesMutedRules() {
        let suite = "LockScreenPolicyTests.masterLockScreenSwitchPreservesMutedRules"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()

        var disabledPolicy = settings.lockScreenPolicies[0]
        disabledPolicy.isEnabled = false
        settings.updateLockScreenPolicy(disabledPolicy)
        settings.setLockScreenPoliciesEnabled(true)

        #expect(settings.lockScreenPoliciesEnabled)
        #expect(settings.lockScreenPolicies.allSatisfy { !$0.isEnabled })

        let loaded = MonitorSettings(defaults: defaults)
        #expect(loaded.lockScreenPoliciesEnabled)
        #expect(loaded.lockScreenPolicies.allSatisfy { !$0.isEnabled })
    }

    @Test func mutedRuleDoesNotResolveOrScheduleTransitions() throws {
        let policy = LockScreenPolicy(
            isEnabled: false,
            startMinutes: 0,
            endMinutes: 24 * 60,
            idleMinutes: 5
        )
        let now = try #require(Calendar.current.date(
            from: DateComponents(year: 2026, month: 8, day: 9, hour: 12)
        ))

        let resolution = LockScreenPolicyResolver.resolve(
            policies: [policy],
            at: now,
            powerSource: .connected
        )

        #expect(resolution.selectedPolicy == nil)
        #expect(resolution.timeActivePolicies.isEmpty)
        #expect(policy.transitionDates(after: now).isEmpty)
    }

    @Test @MainActor func allMutedRulesKeepTheLockEnvironmentInactive() {
        let suite = "LockScreenPolicyTests.allMutedRulesKeepTheLockEnvironmentInactive"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()
        settings.updateLockScreenPolicy(id: settings.lockScreenPolicies[0].id) {
            $0.isEnabled = false
        }
        settings.setLockScreenPoliciesEnabled(true)
        let probe = LockAttemptProbe()
        let controller = LockScreenPolicyController(
            idleSecondsProvider: { probe.idleSeconds },
            requestNativeLock: { false },
            requestKeyboardLock: { false },
            screenLockedProvider: { false },
            powerSourceProvider: { .connected },
            environment: probe.environment
        )

        controller.configure(settings: settings)

        #expect(controller.status == .noRules)
        #expect(!probe.screenSaverDisabled)
        #expect(probe.assertionAcquisitions == 0)
    }

    @Test func legacyRuleWithoutEnabledFieldDefaultsToEnabled() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","dayScope":"everyDay","startMinutes":540,"endMinutes":1080,"idleMinutes":10}
        """

        let policy = try JSONDecoder().decode(LockScreenPolicy.self, from: Data(json.utf8))
        #expect(policy.isEnabled)
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
        settings.updateLockScreenPolicy(id: id) { $0.name = "工作时间" }

        let policy = settings.lockScreenPolicies[0]
        #expect(policy.startMinutes == 20 * 60)
        #expect(policy.endMinutes == 24 * 60)
        #expect(policy.idleMinutes == 37)
        #expect(policy.name == "工作时间")
    }

    @Test func overnightInputIsNormalizedBeforePersistence() {
        let suite = "LockScreenPolicyTests.overnightInputIsNormalizedBeforePersistence"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()
        let id = settings.lockScreenPolicies[0].id

        settings.updateLockScreenPolicy(id: id) {
            $0.setStartMinutes(22 * 60)
            $0.setEndMinutes(6 * 60)
        }

        #expect(settings.lockScreenPolicies[0].endMinutes == 30 * 60)
        #expect(settings.lockScreenPolicies[0].timeRangeText == "22:00 - 30:00")
        let loaded = MonitorSettings(defaults: defaults)
        #expect(loaded.lockScreenPolicies[0].endMinutes == 30 * 60)
        #expect(loaded.lockScreenPolicies[0].timeRangeText == "22:00 - 30:00")
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

    @Test func addedPolicyUsesTheFirstAvailableDefaultName() {
        let suite = "LockScreenPolicyTests.addedPolicyUsesTheFirstAvailableDefaultName"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()
        settings.addLockScreenPolicy()
        settings.addLockScreenPolicy()

        settings.removeLockScreenPolicy(id: settings.lockScreenPolicies[1].id)
        settings.addLockScreenPolicy()

        #expect(settings.lockScreenPolicies.map(\.name) == ["时间段 1", "时间段 3", "时间段 2"])
    }

    @Test func addedPolicyReservesFallbackNamesFromLegacyRules() throws {
        let suite = "LockScreenPolicyTests.addedPolicyReservesFallbackNamesFromLegacyRules"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let firstID = UUID()
        let secondID = UUID()
        let legacyJSON = """
        [
          {"id":"\(firstID.uuidString)","isEnabled":true,"dayScope":"everyDay","startMinutes":0,"endMinutes":420,"idleMinutes":5},
          {"id":"\(secondID.uuidString)","isEnabled":true,"dayScope":"everyDay","startMinutes":420,"endMinutes":1440,"idleMinutes":20}
        ]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "settings.lockScreen.policies")
        let settings = MonitorSettings(defaults: defaults)

        settings.addLockScreenPolicy()

        #expect(settings.lockScreenPolicies.map(\.name) == ["", "", "时间段 3"])
    }

    @Test func policyNameIsNormalizedAtTheSettingsBoundary() {
        let suite = "LockScreenPolicyTests.policyNameIsNormalizedAtTheSettingsBoundary"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        settings.addLockScreenPolicy()
        let id = settings.lockScreenPolicies[0].id

        settings.updateLockScreenPolicy(id: id) {
            $0.name = "  这是一个超过十六个字符的自定义锁屏时间段名称  "
        }

        #expect(settings.lockScreenPolicies[0].name == "这是一个超过十六个字符的自定义锁")
        #expect(settings.lockScreenPolicies[0].name.count == LockScreenPolicy.maximumNameLength)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        date(year, month, day, hour, minute, calendar: calendar)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
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
