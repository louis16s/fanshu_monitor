import Combine
import Foundation
import AppKit
import IOKit.ps
import OSLog

struct LockScreenAttemptTiming: Sendable {
    let pollInterval: Duration
    let maximumPollCount: Int
    let keyboardFallbackPoll: Int
    let retryDelay: TimeInterval

    nonisolated static let standard = LockScreenAttemptTiming(
        pollInterval: .milliseconds(250),
        maximumPollCount: 32,
        keyboardFallbackPoll: 4,
        retryDelay: 10
    )
}

enum LockScreenAttemptResult: Equatable, Sendable {
    case locked
    case failed
    case cancelled
}

enum LockScreenAttemptRunner {
    @MainActor
    static func run(
        timing: LockScreenAttemptTiming,
        requestNativeLock: @MainActor @Sendable () -> Bool,
        requestKeyboardLock: @MainActor @Sendable () -> Bool,
        isScreenLocked: @MainActor @Sendable () -> Bool,
        shouldContinue: @MainActor @Sendable () -> Bool = { true }
    ) async -> LockScreenAttemptResult {
        guard shouldContinue() else { return .cancelled }
        let nativeRequested = requestNativeLock()
        var keyboardRequested = false
        if !nativeRequested {
            AppLogger.lockScreen.warning("Native lock service unavailable; trying keyboard fallback")
            keyboardRequested = requestKeyboardLock()
            if !keyboardRequested { return .failed }
        }

        for poll in 0...timing.maximumPollCount {
            guard !Task.isCancelled, shouldContinue() else { return .cancelled }
            if isScreenLocked() { return .locked }

            if nativeRequested,
               !keyboardRequested,
               poll == timing.keyboardFallbackPoll {
                guard shouldContinue() else { return .cancelled }
                AppLogger.lockScreen.warning("Native lock was not confirmed; trying keyboard fallback")
                keyboardRequested = requestKeyboardLock()
            }

            guard poll < timing.maximumPollCount else { break }
            do {
                try await Task.sleep(for: timing.pollInterval)
            } catch {
                return .cancelled
            }
        }
        return .failed
    }
}

struct LockScreenSystemEnvironment {
    let readSettings: @MainActor () -> ScreenSaverLockBaseline
    let applySettings: @MainActor (Int, Bool, Int) -> Bool
    let disableIdleScreenSaver: @MainActor () -> Bool
    let isIdleScreenSaverDisabled: @MainActor () -> Bool
    let restoreSettings: @MainActor (ScreenSaverLockBaseline) -> Bool
    let acquireDisplaySleepAssertion: @MainActor () -> Bool
    let releaseDisplaySleepAssertion: @MainActor () -> Void

    @MainActor
    static func live() -> LockScreenSystemEnvironment {
        let assertion = IdleDisplaySleepAssertion()
        return LockScreenSystemEnvironment(
            readSettings: ScreenSaverLockPreferences.read,
            applySettings: { idleSeconds, requirePassword, delay in
                ScreenSaverLockPreferences.apply(
                    idleSeconds: idleSeconds,
                    requirePassword: requirePassword,
                    passwordDelaySeconds: delay
                )
            },
            disableIdleScreenSaver: ScreenSaverLockPreferences.disableIdleScreenSaver,
            isIdleScreenSaverDisabled: { ScreenSaverLockPreferences.isIdleScreenSaverDisabled },
            restoreSettings: ScreenSaverLockPreferences.restore,
            acquireDisplaySleepAssertion: { assertion.acquire() },
            releaseDisplaySleepAssertion: { assertion.release() }
        )
    }
}

@MainActor
final class LockScreenPolicyController: ObservableObject {
    @Published private(set) var activePolicy: LockScreenPolicy?
    @Published private(set) var nextTransition: Date?
    @Published private(set) var status = LockScreenPolicyStatus.disabled
    @Published private(set) var systemSettings: ScreenSaverLockBaseline
    var statusText: String { status.text }

    private weak var settings: MonitorSettings?
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var systemObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var transitionTimer: Timer?
    private var idleLockTimer: Timer?
    private var sessionWatchdogTimer: Timer?
    private var lockAttemptTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var environmentMaintenanceTimer: Timer?
    private var baselineRestoreRetryTimer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var lastAppliedConfiguration: AppliedConfiguration?
    private var baselineIsRestored = false
    private var didRequestLockForCurrentIdlePeriod = false
    private let idleSecondsProvider: @MainActor @Sendable () -> TimeInterval
    private let requestNativeLock: @MainActor @Sendable () -> Bool
    private let requestKeyboardLock: @MainActor @Sendable () -> Bool
    private let screenLockedProvider: @MainActor @Sendable () -> Bool
    private let powerSourceProvider: @MainActor @Sendable () -> SystemPowerSourceState
    private let attemptTiming: LockScreenAttemptTiming
    private let recoveryDelay: Duration
    private let baselineRestoreRetryInterval: TimeInterval
    private let environment: LockScreenSystemEnvironment
    private var isSleeping = false
    private var isSessionActive = true

    private struct AppliedConfiguration: Equatable {
        let policyID: LockScreenPolicy.ID
        let idleSeconds: Int
    }

    init(
        idleSecondsProvider: @escaping @MainActor @Sendable () -> TimeInterval = SystemIdleTime.secondsSinceLastInput,
        requestNativeLock: @escaping @MainActor @Sendable () -> Bool = DirectScreenLocker.requestNativeLock,
        requestKeyboardLock: @escaping @MainActor @Sendable () -> Bool = DirectScreenLocker.requestKeyboardLock,
        screenLockedProvider: @escaping @MainActor @Sendable () -> Bool = SystemSessionState.isScreenLocked,
        powerSourceProvider: @escaping @MainActor @Sendable () -> SystemPowerSourceState = SystemPowerSource.currentState,
        attemptTiming: LockScreenAttemptTiming = .standard,
        recoveryDelay: Duration = .seconds(1),
        baselineRestoreRetryInterval: TimeInterval = 60,
        environment: LockScreenSystemEnvironment? = nil
    ) {
        let resolvedEnvironment = environment ?? .live()
        self.idleSecondsProvider = idleSecondsProvider
        self.requestNativeLock = requestNativeLock
        self.requestKeyboardLock = requestKeyboardLock
        self.screenLockedProvider = screenLockedProvider
        self.powerSourceProvider = powerSourceProvider
        self.attemptTiming = attemptTiming
        self.recoveryDelay = recoveryDelay
        self.baselineRestoreRetryInterval = baselineRestoreRetryInterval
        self.environment = resolvedEnvironment
        systemSettings = resolvedEnvironment.readSettings()
    }

    func configure(settings: MonitorSettings) {
        tearDown()
        self.settings = settings
        AppLogger.lockScreen.notice(
            "Lock policy controller configured; enabled: \(settings.lockScreenPoliciesEnabled, privacy: .public)"
        )

        settings.$lockScreenPoliciesEnabled
        .dropFirst()
        .sink { [weak self, weak settings] enabled in
            guard let self, let settings else { return }
            if enabled {
                DispatchQueue.main.async { [weak self] in self?.reevaluate() }
            } else {
                self.deactivatePolicies(using: settings)
            }
        }
        .store(in: &cancellables)

        settings.$lockScreenPolicies
        .dropFirst()
        .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.reevaluate() }
        .store(in: &cancellables)

        reevaluate()
    }

    func restoreOriginalSettings() {
        guard let settings else { return }
        cancelIdleLockTimer()
        cancelLockAttempt()
        cancelRecoveryTask()
        stopDirectLockEnvironment()
        let restored = restoreBaseline(using: settings)
        settings.lockScreenPoliciesEnabled = false
        activePolicy = nil
        nextTransition = nil
        if restored { status = .restored }
        refreshSystemSettings()
    }

    func refreshSystemSettings() {
        systemSettings = environment.readSettings()
    }

    func applySystemSettings(
        idleMinutes: Int,
        requirePassword: Bool,
        passwordDelaySeconds: Int
    ) {
        guard let settings else { return }
        guard !settings.lockScreenPoliciesEnabled else {
            status = .systemSettingsBlocked
            return
        }

        let succeeded = environment.applySettings(
            min(1_440, max(1, idleMinutes)) * 60,
            requirePassword,
            min(86_400, max(0, passwordDelaySeconds))
        )
        refreshSystemSettings()
        if succeeded {
            settings.lockScreenBaseline = nil
            status = .systemSettingsChanged
        } else {
            status = .environmentFailed(reason: "无法保存系统锁屏设置")
            AppLogger.lockScreen.error("System lock preferences failed read-back verification")
        }
    }

    func reevaluate(now: Date = Date()) {
        guard let settings else { return }

        guard settings.lockScreenPoliciesEnabled else {
            deactivatePolicies(using: settings)
            return
        }
        guard !isSleeping, isSessionActive else { return }

        setSystemEventObserving(true)

        let powerSource = powerSourceProvider()
        let resolution = LockScreenPolicyResolver.resolve(
            policies: settings.lockScreenPolicies,
            at: now,
            powerSource: powerSource
        )
        guard let policy = resolution.selectedPolicy else {
            cancelIdleLockTimer()
            cancelLockAttempt()
            stopDirectLockEnvironment()
            didRequestLockForCurrentIdlePeriod = false
            let restored = restoreBaseline(using: settings)
            activePolicy = nil
            if restored, settings.lockScreenPolicies.isEmpty {
                status = .noRules
            } else if restored, let waitingPolicy = resolution.waitingPolicy {
                status = powerSource == .unknown
                    ? .waitingForPowerSource
                    : .waitingForPower(waitingPolicy.powerCondition)
            } else if restored, let next = settings.lockScreenPolicies
                .flatMap({ $0.transitionDates(after: now) })
                .min() {
                status = .waiting(nextTransition: next)
            } else if restored {
                status = .waiting(nextTransition: nil)
            }
            scheduleNextTransition(after: now, policies: settings.lockScreenPolicies)
            return
        }

        cancelBaselineRestoreRetry()
        captureBaselineIfNeeded(using: settings)
        let configuration = AppliedConfiguration(
            policyID: policy.id,
            idleSeconds: policy.idleMinutes * 60
        )
        if configuration != lastAppliedConfiguration {
            cancelIdleLockTimer()
            cancelLockAttempt()
            didRequestLockForCurrentIdlePeriod = false
            lastAppliedConfiguration = configuration
        }
        activePolicy = policy
        maintainDirectLockEnvironment()
        baselineIsRestored = false
        if lockAttemptTask == nil,
           !screenLockedProvider(),
           !status.isEnvironmentFailure {
            status = .active(timeRange: policy.timeRangeText, idleMinutes: policy.idleMinutes)
        }
        scheduleIdleLock(for: policy)
        scheduleNextTransition(after: now, policies: settings.lockScreenPolicies)
    }

    private func scheduleNextTransition(after date: Date, policies: [LockScreenPolicy]) {
        let transition = policies
            .flatMap { $0.transitionDates(after: date) }
            .min()
        guard transition != nextTransition || transitionTimer == nil else { return }

        transitionTimer?.invalidate()
        nextTransition = transition
        guard let transition else { return }

        let interval = max(1, transition.timeIntervalSince(date) + 0.5)
        transitionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reevaluate() }
        }
    }

    private func captureBaselineIfNeeded(using settings: MonitorSettings) {
        guard settings.lockScreenBaseline == nil else { return }
        settings.lockScreenBaseline = environment.readSettings()
        baselineIsRestored = false
    }

    private func deactivatePolicies(using settings: MonitorSettings) {
        setSystemEventObserving(false)
        cancelIdleLockTimer()
        cancelLockAttempt()
        cancelRecoveryTask()
        stopDirectLockEnvironment()
        didRequestLockForCurrentIdlePeriod = false
        let restored = restoreBaseline(using: settings)
        activePolicy = nil
        cancelTransitionTimer()
        if restored { status = .disabled }
    }

    private func scheduleIdleLock(for policy: LockScreenPolicy) {
        cancelIdleLockTimer()
        if screenLockedProvider() {
            markSessionLocked()
            return
        }
        let threshold = TimeInterval(policy.idleMinutes * 60)
        let idleSeconds = max(0, idleSecondsProvider())

        if idleSeconds >= threshold {
            guard !didRequestLockForCurrentIdlePeriod else { return }
            didRequestLockForCurrentIdlePeriod = true
            status = .locking
            startLockAttempt(for: policy.id)
            return
        }

        didRequestLockForCurrentIdlePeriod = false
        scheduleIdleLockRetry(after: DirectLockSchedule.remainingDelay(
            idleSeconds: idleSeconds,
            threshold: threshold
        ))
    }

    private func scheduleIdleLockRetry(after delay: TimeInterval) {
        idleLockTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let policy = self.activePolicy else { return }
                self.scheduleIdleLock(for: policy)
            }
        }
    }

    private func cancelIdleLockTimer() {
        idleLockTimer?.invalidate()
        idleLockTimer = nil
    }

    private func startLockAttempt(for policyID: LockScreenPolicy.ID) {
        cancelLockAttempt()
        lockAttemptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await LockScreenAttemptRunner.run(
                timing: self.attemptTiming,
                requestNativeLock: self.requestNativeLock,
                requestKeyboardLock: self.requestKeyboardLock,
                isScreenLocked: self.screenLockedProvider,
                shouldContinue: { [weak self] in
                    self?.settings?.lockScreenPoliciesEnabled == true
                        && self?.activePolicy?.id == policyID
                        && self?.status == .locking
                }
            )
            guard !Task.isCancelled,
                  self.activePolicy?.id == policyID,
                  self.status == .locking else {
                return
            }

            switch result {
            case .locked:
                self.markSessionLocked()
            case .failed:
                self.lockAttemptTask = nil
                self.didRequestLockForCurrentIdlePeriod = false
                self.status = .lockFailed
                AppLogger.lockScreen.error("The system did not confirm the lock request")
                self.scheduleIdleLockRetry(after: self.attemptTiming.retryDelay)
            case .cancelled:
                break
            }
        }
    }

    private func cancelLockAttempt() {
        lockAttemptTask?.cancel()
        lockAttemptTask = nil
    }

    private func markSessionLocked() {
        cancelLockAttempt()
        stopDirectLockEnvironment()
        status = .locked
        AppLogger.lockScreen.notice("System session lock confirmed")
    }

    private func maintainDirectLockEnvironment() {
        let screenSaverReady: Bool
        if environment.isIdleScreenSaverDisabled() {
            screenSaverReady = true
        } else {
            screenSaverReady = environment.disableIdleScreenSaver()
            refreshSystemSettings()
        }
        let assertionReady = environment.acquireDisplaySleepAssertion()

        if !screenSaverReady {
            status = .environmentFailed(reason: "无法关闭系统屏保，将自动重试")
            AppLogger.lockScreen.error("Unable to disable the idle screen saver")
        } else if !assertionReady {
            status = .environmentFailed(reason: "无法阻止显示器提前休眠，将自动重试")
            AppLogger.lockScreen.error("Unable to acquire the idle display sleep assertion")
        } else if case .environmentFailed = status, let policy = activePolicy {
            status = .active(timeRange: policy.timeRangeText, idleMinutes: policy.idleMinutes)
        }

        guard environmentMaintenanceTimer == nil else { return }
        environmentMaintenanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activePolicy != nil else { return }
                self.maintainDirectLockEnvironment()
            }
        }
    }

    private func stopDirectLockEnvironment() {
        environmentMaintenanceTimer?.invalidate()
        environmentMaintenanceTimer = nil
        environment.releaseDisplaySleepAssertion()
    }

    @discardableResult
    private func restoreBaseline(using settings: MonitorSettings, clear: Bool = true) -> Bool {
        guard let baseline = settings.lockScreenBaseline else {
            cancelBaselineRestoreRetry()
            return true
        }
        if !baselineIsRestored {
            guard environment.restoreSettings(baseline) else {
                status = .environmentFailed(reason: "无法恢复系统原设置")
                AppLogger.lockScreen.error("Unable to restore the original system lock preferences")
                scheduleBaselineRestoreRetry()
                return false
            }
            lastAppliedConfiguration = nil
            baselineIsRestored = true
        }
        cancelBaselineRestoreRetry()
        if clear {
            settings.lockScreenBaseline = nil
        }
        return true
    }

    private func scheduleBaselineRestoreRetry() {
        guard baselineRestoreRetryTimer == nil else { return }
        baselineRestoreRetryTimer = Timer.scheduledTimer(
            withTimeInterval: baselineRestoreRetryInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let settings = self.settings else { return }
                self.baselineRestoreRetryTimer = nil
                guard self.restoreBaseline(using: settings) else { return }

                if !settings.lockScreenPoliciesEnabled {
                    self.status = .disabled
                } else if !self.isSessionActive {
                    self.status = .sessionInactive
                } else if !self.isSleeping {
                    self.reevaluate()
                }
            }
        }
        baselineRestoreRetryTimer?.tolerance = min(5, baselineRestoreRetryInterval * 0.2)
    }

    private func cancelBaselineRestoreRetry() {
        baselineRestoreRetryTimer?.invalidate()
        baselineRestoreRetryTimer = nil
    }

    private func setSystemEventObserving(_ enabled: Bool) {
        if enabled {
            setPowerSourceObserving(true)
        }
        let isObserving = !workspaceObservers.isEmpty
            || !systemObservers.isEmpty
            || !distributedObservers.isEmpty
        guard enabled != isObserving else { return }
        if !enabled {
            setPowerSourceObserving(false)
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            systemObservers.forEach(NotificationCenter.default.removeObserver)
            distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
            workspaceObservers.removeAll()
            systemObservers.removeAll()
            distributedObservers.removeAll()
            sessionWatchdogTimer?.invalidate()
            sessionWatchdogTimer = nil
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemDidWake()
                }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemWillSleep()
                }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionDidBecomeActive()
                }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionDidResignActive()
                }
            }
        ]
        systemObservers = [
            NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reevaluate() }
            },
            NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reevaluate() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.prepareForTermination()
                }
            }
        ]

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers = [
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleScreenDidLock()
                }
            },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSessionDidBecomeActive()
                }
            }
        ]

        sessionWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileSessionState()
            }
        }
        sessionWatchdogTimer?.tolerance = 5
    }

    private func setPowerSourceObserving(_ enabled: Bool) {
        if !enabled {
            if let powerSourceRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
            }
            powerSourceRunLoopSource = nil
            return
        }
        guard powerSourceRunLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSourceRunLoopSource = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let controller = Unmanaged<LockScreenPolicyController>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor in
                controller.reevaluate()
            }
        }, context)?.takeRetainedValue()
        if let powerSourceRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
        }
    }

    func handleSystemWillSleep() {
        AppLogger.lockScreen.notice("System will sleep; pausing lock policy")
        isSleeping = true
        cancelRecoveryTask()
        cancelTransitionTimer()
        cancelIdleLockTimer()
        cancelLockAttempt()
        stopDirectLockEnvironment()
        setPowerSourceObserving(false)
    }

    func handleSystemDidWake() {
        AppLogger.lockScreen.notice("System did wake; scheduling lock policy recovery")
        isSleeping = false
        scheduleRecovery(after: recoveryDelay)
    }

    func handleSessionDidBecomeActive() {
        AppLogger.lockScreen.notice("User session became active; resuming lock policy")
        isSessionActive = true
        cancelLockAttempt()
        didRequestLockForCurrentIdlePeriod = false
        guard !isSleeping else {
            AppLogger.lockScreen.notice("Session activation deferred until system wake")
            return
        }
        guard recoveryTask == nil else { return }
        reevaluate()
    }

    func handleSessionDidResignActive() {
        AppLogger.lockScreen.notice("User session resigned active state")
        isSessionActive = false
        cancelTransitionTimer()
        setPowerSourceObserving(false)
        if screenLockedProvider() {
            markSessionLocked()
        } else {
            cancelIdleLockTimer()
            cancelLockAttempt()
            stopDirectLockEnvironment()
            didRequestLockForCurrentIdlePeriod = false
            if let settings, restoreBaseline(using: settings) {
                status = .sessionInactive
            }
        }
    }

    func handleScreenDidLock() {
        isSessionActive = false
        cancelTransitionTimer()
        setPowerSourceObserving(false)
        markSessionLocked()
    }

    func reconcileSessionState() {
        guard settings?.lockScreenPoliciesEnabled == true else { return }
        let isLocked = screenLockedProvider()
        if isLocked, status != .locked {
            AppLogger.lockScreen.warning("Session watchdog recovered a missed lock notification")
            handleScreenDidLock()
        } else if !isLocked, status == .locked {
            AppLogger.lockScreen.warning("Session watchdog recovered a missed unlock notification")
            handleSessionDidBecomeActive()
        }
    }

    func prepareForTermination() {
        cancelIdleLockTimer()
        cancelLockAttempt()
        cancelRecoveryTask()
        cancelBaselineRestoreRetry()
        stopDirectLockEnvironment()
        if let settings {
            restoreBaselineForTermination(using: settings)
        }
    }

    private func restoreBaselineForTermination(using settings: MonitorSettings) {
        guard let baseline = settings.lockScreenBaseline else { return }
        guard environment.restoreSettings(baseline) else {
            AppLogger.lockScreen.error("Unable to restore system lock preferences before termination")
            return
        }
        settings.lockScreenBaseline = nil
        baselineIsRestored = true
        lastAppliedConfiguration = nil
    }

    private func scheduleRecovery(after delay: Duration) {
        cancelRecoveryTask()
        recoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.recoveryTask = nil
            guard !self.isSleeping else {
                AppLogger.lockScreen.notice("Lock policy recovery skipped while system is sleeping")
                return
            }
            self.lastAppliedConfiguration = nil
            self.didRequestLockForCurrentIdlePeriod = false
            AppLogger.lockScreen.notice("Lock policy recovery completed")
            self.reevaluate()
        }
    }

    private func cancelRecoveryTask() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func cancelTransitionTimer() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        nextTransition = nil
    }

    private func tearDown() {
        cancelTransitionTimer()
        cancelIdleLockTimer()
        cancelLockAttempt()
        cancelRecoveryTask()
        cancelBaselineRestoreRetry()
        stopDirectLockEnvironment()
        sessionWatchdogTimer?.invalidate()
        sessionWatchdogTimer = nil
        cancellables.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        systemObservers.forEach(NotificationCenter.default.removeObserver)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        workspaceObservers.removeAll()
        systemObservers.removeAll()
        distributedObservers.removeAll()
        setPowerSourceObserving(false)
    }

    deinit {
        transitionTimer?.invalidate()
        idleLockTimer?.invalidate()
        lockAttemptTask?.cancel()
        recoveryTask?.cancel()
        baselineRestoreRetryTimer?.invalidate()
        environmentMaintenanceTimer?.invalidate()
        sessionWatchdogTimer?.invalidate()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        systemObservers.forEach(NotificationCenter.default.removeObserver)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
        }
    }
}
