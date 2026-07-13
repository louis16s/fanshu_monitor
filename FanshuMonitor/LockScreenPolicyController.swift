import Combine
import Foundation
import AppKit

@MainActor
final class LockScreenPolicyController: ObservableObject {
    @Published private(set) var activePolicy: LockScreenPolicy?
    @Published private(set) var nextTransition: Date?
    @Published private(set) var statusText = "未启用"
    @Published private(set) var systemSettings = ScreenSaverLockPreferences.read()

    private weak var settings: MonitorSettings?
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var transitionTimer: Timer?
    private var lastAppliedConfiguration: AppliedConfiguration?
    private var baselineIsRestored = false

    private struct AppliedConfiguration: Equatable {
        let policyID: LockScreenPolicy.ID
        let idleSeconds: Int
        let requirePassword: Bool
    }

    func configure(settings: MonitorSettings) {
        tearDown()
        self.settings = settings

        Publishers.MergeMany(
            settings.$lockScreenPoliciesEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$lockScreenRequirePassword.map { _ in () }.eraseToAnyPublisher(),
            settings.$lockScreenPolicies.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst()
        .sink { [weak self] in self?.reevaluate() }
        .store(in: &cancellables)

        reevaluate()
    }

    func restoreOriginalSettings() {
        guard let settings else { return }
        restoreBaseline(using: settings)
        settings.lockScreenPoliciesEnabled = false
        activePolicy = nil
        nextTransition = nil
        statusText = "已恢复系统原设置"
        refreshSystemSettings()
    }

    func refreshSystemSettings() {
        systemSettings = ScreenSaverLockPreferences.read()
    }

    func applySystemSettings(
        idleMinutes: Int,
        requirePassword: Bool,
        passwordDelaySeconds: Int
    ) {
        guard let settings else { return }
        guard !settings.lockScreenPoliciesEnabled else {
            statusText = "请先关闭时间策略再修改系统设置"
            return
        }

        ScreenSaverLockPreferences.apply(
            idleSeconds: min(1_440, max(1, idleMinutes)) * 60,
            requirePassword: requirePassword,
            passwordDelaySeconds: min(86_400, max(0, passwordDelaySeconds))
        )
        settings.lockScreenBaseline = nil
        refreshSystemSettings()
        statusText = "已修改系统锁屏设置"
    }

    func reevaluate(now: Date = Date()) {
        guard let settings else { return }

        guard settings.lockScreenPoliciesEnabled else {
            setSystemEventObserving(false)
            restoreBaseline(using: settings)
            activePolicy = nil
            cancelTransitionTimer()
            statusText = "未启用"
            return
        }

        setSystemEventObserving(true)

        guard let policy = settings.lockScreenPolicies.first(where: { $0.isActive(at: now) }) else {
            restoreBaseline(using: settings, clear: false)
            activePolicy = nil
            statusText = settings.lockScreenPolicies.isEmpty ? "请添加至少一个时间策略" : "当前时段沿用系统设置"
            scheduleNextTransition(after: now, policies: settings.lockScreenPolicies)
            return
        }

        captureBaselineIfNeeded(using: settings)
        let configuration = AppliedConfiguration(
            policyID: policy.id,
            idleSeconds: policy.idleMinutes * 60,
            requirePassword: settings.lockScreenRequirePassword
        )
        if configuration != lastAppliedConfiguration {
            ScreenSaverLockPreferences.apply(
                idleSeconds: configuration.idleSeconds,
                requirePassword: configuration.requirePassword
            )
            lastAppliedConfiguration = configuration
        }
        baselineIsRestored = false
        activePolicy = policy
        statusText = "当前策略：\(policy.dayScope.title) \(policy.timeRangeText)，\(policy.idleMinutes) 分钟后锁屏"
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
            Task { @MainActor in self?.reevaluate() }
        }
    }

    private func captureBaselineIfNeeded(using settings: MonitorSettings) {
        guard settings.lockScreenBaseline == nil else { return }
        settings.lockScreenBaseline = ScreenSaverLockPreferences.read()
        baselineIsRestored = false
    }

    private func restoreBaseline(using settings: MonitorSettings, clear: Bool = true) {
        guard let baseline = settings.lockScreenBaseline else { return }
        guard !baselineIsRestored else { return }
        ScreenSaverLockPreferences.restore(baseline)
        lastAppliedConfiguration = nil
        baselineIsRestored = true
        if clear {
            settings.lockScreenBaseline = nil
        }
    }

    private func setSystemEventObserving(_ enabled: Bool) {
        let isObserving = !notificationObservers.isEmpty
        guard enabled != isObserving else { return }
        if !enabled {
            notificationObservers.forEach(NotificationCenter.default.removeObserver)
            notificationObservers.removeAll()
            return
        }

        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.lastAppliedConfiguration = nil
                    self?.reevaluate()
                }
            },
            center.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reevaluate() }
            }
        ]
    }

    private func cancelTransitionTimer() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        nextTransition = nil
    }

    private func tearDown() {
        cancelTransitionTimer()
        cancellables.removeAll()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }

    deinit {
        transitionTimer?.invalidate()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

private enum ScreenSaverLockPreferences {
    private static let domain = "com.apple.screensaver" as CFString

    static func read() -> ScreenSaverLockBaseline {
        ScreenSaverLockBaseline(
            idleTime: integer(for: "idleTime", host: true),
            askForPassword: bool(for: "askForPassword", host: false),
            askForPasswordDelay: integer(for: "askForPasswordDelay", host: false)
        )
    }

    static func apply(
        idleSeconds: Int,
        requirePassword: Bool,
        passwordDelaySeconds: Int = 0
    ) {
        set(idleSeconds, for: "idleTime", host: true)
        if requirePassword {
            set(true, for: "askForPassword", host: false)
            set(passwordDelaySeconds, for: "askForPasswordDelay", host: false)
        } else {
            set(false, for: "askForPassword", host: false)
        }
    }

    static func restore(_ baseline: ScreenSaverLockBaseline) {
        set(baseline.idleTime, for: "idleTime", host: true)
        set(baseline.askForPassword, for: "askForPassword", host: false)
        set(baseline.askForPasswordDelay, for: "askForPasswordDelay", host: false)
    }

    private static func integer(for key: String, host: Bool) -> Int? {
        value(for: key, host: host).flatMap { value in
            if let number = value as? NSNumber { return number.intValue }
            return value as? Int
        }
    }

    private static func bool(for key: String, host: Bool) -> Bool? {
        value(for: key, host: host).flatMap { value in
            if let number = value as? NSNumber { return number.boolValue }
            return value as? Bool
        }
    }

    private static func value(for key: String, host: Bool) -> Any? {
        CFPreferencesCopyValue(
            key as CFString,
            domain,
            kCFPreferencesCurrentUser,
            host ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        )
    }

    private static func set(_ value: Any?, for key: String, host: Bool) {
        let hostScope = host ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        CFPreferencesSetValue(
            key as CFString,
            value as CFPropertyList?,
            domain,
            kCFPreferencesCurrentUser,
            hostScope
        )
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, hostScope)
    }
}
