import Combine
import Foundation
import ServiceManagement
import SwiftUI

enum AppThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            String(localized: "theme.system")
        case .light:
            String(localized: "theme.light")
        case .dark:
            String(localized: "theme.dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

enum MonitorColorSchemePreference: String, CaseIterable, Identifiable {
    case systemBlue
    case graphite
    case teal
    case rose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemBlue:
            String(localized: "color-scheme.system-blue")
        case .graphite:
            String(localized: "color-scheme.graphite")
        case .teal:
            String(localized: "color-scheme.teal")
        case .rose:
            String(localized: "color-scheme.rose")
        }
    }
}

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            String(localized: "language.system")
        case .english:
            String(localized: "language.english")
        }
    }

    var locale: Locale? {
        switch self {
        case .system:
            nil
        case .english:
            Locale(identifier: "en")
        }
    }
}

final class MonitorSettings: ObservableObject {
    @Published var launchAtLogin: Bool = false
    @Published var themePreference: AppThemePreference = .system
    @Published var languagePreference: AppLanguagePreference = .system
    @Published var colorSchemePreference: MonitorColorSchemePreference = .systemBlue
    @Published var ringSource: HaloRingSource = .combined
    @Published var showBuiltInDisplays: Bool = true
    @Published var displayModuleVisible: Bool = true
    @Published var displayBrightnessControlEnabled: Bool = true
    @Published var displayVolumeControlEnabled: Bool = true
    @Published var displayContrastControlEnabled: Bool = false
    @Published var displayAvailabilityHintsEnabled: Bool = true
    @Published var displayNativeOSDEnabled: Bool = true
    @Published var displaySoftwareDimmingEnabled: Bool = true
    @Published var brightnessKeyStepPercent: Double = 5
    @Published var codexRefreshIntervalMinutes: Double = 5
    @Published var updateChecksEnabled: Bool = true
    @Published var brightnessKeyInterceptionEnabled: Bool = true
    @Published var mouseControlEnabled: Bool = false
    @Published var mouseDPIOnDemandEnabled: Bool = true
    @Published var mouseDPI: Double = 1600
    @Published var mouseMiddleAction: MouseButtonAction = .passThrough
    @Published var mouseBackAction: MouseButtonAction = .paste
    @Published var mouseForwardAction: MouseButtonAction = .launchpad
    @Published var mouseGestureAction: MouseButtonAction = .passThrough
    @Published var lockScreenPoliciesEnabled: Bool = false
    @Published var lockScreenRequirePassword: Bool = true
    @Published private(set) var lockScreenPolicies: [LockScreenPolicy] = []
    @Published private(set) var visibleKinds: Set<MonitorKind> = []
    @Published private(set) var enabledMetrics: [MonitorKind: Set<String>] = [:]

    static let maximumEnabledMetricsPerKind = 4
    static let maximumLockScreenPolicies = 4

    private let defaults: UserDefaults
    private var isUpdatingLaunchAtLogin = false
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let themeRawValue = defaults.string(forKey: Keys.themePreference) ?? AppThemePreference.system.rawValue
        themePreference = AppThemePreference(rawValue: themeRawValue) ?? .system

        let languageRawValue = defaults.string(forKey: Keys.languagePreference) ?? AppLanguagePreference.system.rawValue
        languagePreference = AppLanguagePreference(rawValue: languageRawValue) ?? .system

        let colorSchemeRawValue = defaults.string(forKey: Keys.colorSchemePreference) ?? MonitorColorSchemePreference.systemBlue.rawValue
        colorSchemePreference = MonitorColorSchemePreference(rawValue: colorSchemeRawValue) ?? .systemBlue

        let ringSourceRawValue = defaults.string(forKey: Keys.ringSource) ?? HaloRingSource.combined.rawValue
        ringSource = HaloRingSource(rawValue: ringSourceRawValue) ?? .combined

        showBuiltInDisplays = defaults.object(forKey: Keys.showBuiltInDisplays) as? Bool ?? true
        displayModuleVisible = defaults.object(forKey: Keys.displayModuleVisible) as? Bool ?? true
        displayBrightnessControlEnabled = defaults.object(forKey: Keys.displayBrightnessControlEnabled) as? Bool ?? true
        displayVolumeControlEnabled = defaults.object(forKey: Keys.displayVolumeControlEnabled) as? Bool ?? true
        displayContrastControlEnabled = defaults.object(forKey: Keys.displayContrastControlEnabled) as? Bool ?? false
        displayAvailabilityHintsEnabled = defaults.object(forKey: Keys.displayAvailabilityHintsEnabled) as? Bool ?? true
        displayNativeOSDEnabled = defaults.object(forKey: Keys.displayNativeOSDEnabled) as? Bool ?? true
        displaySoftwareDimmingEnabled = defaults.object(forKey: Keys.displaySoftwareDimmingEnabled) as? Bool ?? true
        brightnessKeyStepPercent = defaults.object(forKey: Keys.brightnessKeyStepPercent) as? Double ?? 5
        codexRefreshIntervalMinutes = defaults.object(forKey: Keys.codexRefreshIntervalMinutes) as? Double ?? 5
        updateChecksEnabled = defaults.object(forKey: Keys.updateChecksEnabled) as? Bool ?? true
        brightnessKeyInterceptionEnabled = defaults.object(forKey: Keys.brightnessKeyInterceptionEnabled) as? Bool ?? true
        mouseControlEnabled = defaults.object(forKey: Keys.mouseControlEnabled) as? Bool ?? false
        mouseDPIOnDemandEnabled = defaults.object(forKey: Keys.mouseDPIOnDemandEnabled) as? Bool ?? true
        mouseDPI = defaults.object(forKey: Keys.mouseDPI) as? Double ?? 1600
        mouseMiddleAction = MouseButtonAction(rawValue: defaults.string(forKey: Keys.mouseMiddleAction) ?? "") ?? .passThrough
        mouseBackAction = MouseButtonAction(rawValue: defaults.string(forKey: Keys.mouseBackAction) ?? "") ?? .paste
        mouseForwardAction = MouseButtonAction(rawValue: defaults.string(forKey: Keys.mouseForwardAction) ?? "") ?? .launchpad
        mouseGestureAction = MouseButtonAction(rawValue: defaults.string(forKey: Keys.mouseGestureAction) ?? "") ?? .passThrough
        lockScreenPoliciesEnabled = defaults.object(forKey: Keys.lockScreenPoliciesEnabled) as? Bool ?? false
        lockScreenRequirePassword = defaults.object(forKey: Keys.lockScreenRequirePassword) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.lockScreenPolicies),
           let policies = try? JSONDecoder().decode([LockScreenPolicy].self, from: data) {
            lockScreenPolicies = Array(policies.prefix(Self.maximumLockScreenPolicies))
        }

        if let storedKinds = defaults.array(forKey: Keys.visibleKinds) as? [String] {
            let kinds = storedKinds.compactMap(MonitorKind.init(rawValue:))
            var migratedKinds = Set(kinds)
            if !defaults.bool(forKey: Keys.codexVisibilityMigrated) {
                migratedKinds.insert(.codex)
                defaults.set(true, forKey: Keys.codexVisibilityMigrated)
            }
            visibleKinds = migratedKinds
        } else {
            visibleKinds = Set(MonitorKind.allCases).subtracting([.storage, .network])
            defaults.set(true, forKey: Keys.codexVisibilityMigrated)
        }

        var loadedMetrics: [MonitorKind: Set<String>] = [:]
        for kind in MonitorKind.allCases {
            let key = Keys.enabledMetricsPrefix + kind.rawValue
            if let stored = defaults.array(forKey: key) as? [String] {
                let migrated = migrateMetrics(stored, for: kind)
                loadedMetrics[kind] = Set(migrated)
            }
        }
        enabledMetrics = loadedMetrics

        launchAtLogin = SMAppService.mainApp.status == .enabled

        setupBindings()
    }

    func isVisible(_ kind: MonitorKind) -> Bool {
        visibleKinds.contains(kind)
    }

    func setVisible(_ isVisible: Bool, for kind: MonitorKind) {
        if isVisible {
            visibleKinds.insert(kind)
        } else {
            visibleKinds.remove(kind)
        }
    }

    func isMetricEnabled(_ id: String, for kind: MonitorKind) -> Bool {
        if let stored = enabledMetrics[kind] {
            return stored.contains(id)
        }
        return kind.availableMetrics.first(where: { $0.id == id })?.isDefault ?? false
    }

    func canEnableMetric(_ id: String, for kind: MonitorKind) -> Bool {
        let current = enabledMetrics[kind] ?? defaultMetricIds(for: kind)
        return current.contains(id) || current.count < Self.maximumEnabledMetricsPerKind
    }

    func setMetric(_ id: String, enabled: Bool, for kind: MonitorKind) {
        var current = enabledMetrics[kind] ?? defaultMetricIds(for: kind)
        if enabled {
            guard current.contains(id) || current.count < Self.maximumEnabledMetricsPerKind else {
                return
            }
            current.insert(id)
        } else {
            current.remove(id)
        }
        enabledMetrics[kind] = current
    }

    func resetMetrics(for kind: MonitorKind) {
        enabledMetrics[kind] = defaultMetricIds(for: kind)
    }

    func mouseAction(for slot: MouseButtonSlot) -> MouseButtonAction {
        switch slot {
        case .middle:
            mouseMiddleAction
        case .back:
            mouseBackAction
        case .forward:
            mouseForwardAction
        case .gesture:
            mouseGestureAction
        }
    }

    func setMouseAction(_ action: MouseButtonAction, for slot: MouseButtonSlot) {
        switch slot {
        case .middle:
            mouseMiddleAction = action
        case .back:
            mouseBackAction = action
        case .forward:
            mouseForwardAction = action
        case .gesture:
            mouseGestureAction = action
        }
    }

    func addLockScreenPolicy() {
        guard lockScreenPolicies.count < Self.maximumLockScreenPolicies else { return }
        let newPolicy: LockScreenPolicy
        if let last = lockScreenPolicies.last {
            newPolicy = LockScreenPolicy(
                dayScope: last.dayScope,
                startMinutes: last.endMinutes,
                endMinutes: min(23 * 60 + 59, last.endMinutes + 60),
                idleMinutes: last.idleMinutes
            )
        } else {
            newPolicy = LockScreenPolicy()
        }
        lockScreenPolicies.append(newPolicy)
    }

    func updateLockScreenPolicy(_ policy: LockScreenPolicy) {
        guard let index = lockScreenPolicies.firstIndex(where: { $0.id == policy.id }) else { return }
        lockScreenPolicies[index] = policy
    }

    func removeLockScreenPolicy(id: LockScreenPolicy.ID) {
        lockScreenPolicies.removeAll { $0.id == id }
    }

    var lockScreenBaseline: ScreenSaverLockBaseline? {
        get {
            guard let data = defaults.data(forKey: Keys.lockScreenBaseline) else { return nil }
            return try? JSONDecoder().decode(ScreenSaverLockBaseline.self, from: data)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.lockScreenBaseline)
                return
            }
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.lockScreenBaseline)
        }
    }

    private func migrateMetrics(_ ids: [String], for kind: MonitorKind) -> [String] {
        let mapping: [String: String] = {
            switch kind {
            case .cpu:
                return ["系统": "system", "用户": "user", "闲置": "idle", "温度": "temperature"]
            case .gpu:
                return ["GPU内存": "gpu-memory", "已分配": "allocated", "渲染": "render", "分块": "tiler", "温度": "temperature"]
            case .memory:
                return ["已用": "used", "压力": "pressure", "总量": "total", "App 占用": "app-memory", "缓存": "cached", "已压缩": "compressed"]
            case .storage:
                return ["已用": "used", "可用": "free", "总量": "total"]
            case .network:
                return ["IP 地址": "ipv4", "上传": "upload", "下载": "download", "SSID": "ssid", "IPv4": "ipv4", "IPv6": "ipv6"]
            case .battery:
                return ["充电功率": "charging-power", "健康度": "health", "循环数": "cycle-count", "温度": "temperature", "适配器": "adapter", "功耗": "power"]
            case .codex:
                return [
                    "5H": "five-hour",
                    "一周": "weekly",
                    "下次刷新": "five-hour-reset",
                    "状态": "weekly-reset",
                    "5H刷新": "five-hour-reset",
                    "周刷新": "weekly-reset",
                    "next-reset": "five-hour-reset",
                    "status": "weekly-reset"
                ]
            }
        }()

        var result = Set<String>()
        for id in ids {
            if let mapped = mapping[id] {
                result.insert(mapped)
            } else {
                result.insert(id)
            }
        }

        let availableIds = Set(kind.availableMetrics.map { $0.id })
        let filtered = result.intersection(availableIds)

        if filtered.isEmpty {
            return Array(defaultMetricIds(for: kind))
        }

        return Array(filtered.prefix(Self.maximumEnabledMetricsPerKind))
    }

    private func defaultMetricIds(for kind: MonitorKind) -> Set<String> {
        Set(kind.availableMetrics.filter { $0.isDefault }.map { $0.id })
    }

    private func setupBindings() {
        $launchAtLogin
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persistLaunchAtLogin(newValue)
            }
            .store(in: &cancellables)

        $themePreference
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue.rawValue, forKey: Keys.themePreference)
            }
            .store(in: &cancellables)

        $languagePreference
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue.rawValue, forKey: Keys.languagePreference)
            }
            .store(in: &cancellables)

        $colorSchemePreference
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue.rawValue, forKey: Keys.colorSchemePreference)
            }
            .store(in: &cancellables)

        $ringSource
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue.rawValue, forKey: Keys.ringSource)
            }
            .store(in: &cancellables)

        $showBuiltInDisplays
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.showBuiltInDisplays)
            }
            .store(in: &cancellables)

        $displayModuleVisible
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.displayModuleVisible)
            }
            .store(in: &cancellables)

        $displayBrightnessControlEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.displayBrightnessControlEnabled)
            }
            .store(in: &cancellables)

        $displayVolumeControlEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.displayVolumeControlEnabled)
            }
            .store(in: &cancellables)

        $displayContrastControlEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.displayContrastControlEnabled)
            }
            .store(in: &cancellables)

        $displayAvailabilityHintsEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.displayAvailabilityHintsEnabled)
            }
            .store(in: &cancellables)

        $displayNativeOSDEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.displayNativeOSDEnabled)
            }
            .store(in: &cancellables)

        $displaySoftwareDimmingEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.displaySoftwareDimmingEnabled)
            }
            .store(in: &cancellables)

        $brightnessKeyStepPercent
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(min(20, max(1, newValue)), forKey: Keys.brightnessKeyStepPercent)
            }
            .store(in: &cancellables)

        $codexRefreshIntervalMinutes
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(min(60, max(1, newValue)), forKey: Keys.codexRefreshIntervalMinutes)
            }
            .store(in: &cancellables)

        $updateChecksEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.updateChecksEnabled)
            }
            .store(in: &cancellables)

        $brightnessKeyInterceptionEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.brightnessKeyInterceptionEnabled)
            }
            .store(in: &cancellables)

        $mouseControlEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.mouseControlEnabled)
            }
            .store(in: &cancellables)

        $mouseDPIOnDemandEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.mouseDPIOnDemandEnabled)
            }
            .store(in: &cancellables)

        $mouseDPI
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(min(8000, max(200, newValue)), forKey: Keys.mouseDPI)
            }
            .store(in: &cancellables)

        $mouseMiddleAction
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue.rawValue, forKey: Keys.mouseMiddleAction)
            }
            .store(in: &cancellables)

        $mouseBackAction
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue.rawValue, forKey: Keys.mouseBackAction)
            }
            .store(in: &cancellables)

        $mouseForwardAction
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue.rawValue, forKey: Keys.mouseForwardAction)
            }
            .store(in: &cancellables)

        $mouseGestureAction
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue.rawValue, forKey: Keys.mouseGestureAction)
            }
            .store(in: &cancellables)

        $lockScreenPoliciesEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.lockScreenPoliciesEnabled)
            }
            .store(in: &cancellables)

        $lockScreenRequirePassword
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(newValue, forKey: Keys.lockScreenRequirePassword)
            }
            .store(in: &cancellables)

        $lockScreenPolicies
            .dropFirst()
            .sink { [weak self] newValue in
                self?.persist(try? JSONEncoder().encode(newValue), forKey: Keys.lockScreenPolicies)
            }
            .store(in: &cancellables)

        $visibleKinds
            .dropFirst()
            .sink { [weak self] newValue in
                let values = newValue.map(\.rawValue)
                self?.persist(values, forKey: Keys.visibleKinds)
            }
            .store(in: &cancellables)

        $enabledMetrics
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                for (kind, ids) in newValue {
                    let key = Keys.enabledMetricsPrefix + kind.rawValue
                    self.persist(Array(ids), forKey: key)
                }
            }
            .store(in: &cancellables)
    }

    private func persist<T>(_ value: T, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private func persistLaunchAtLogin(_ newValue: Bool) {
        guard !isUpdatingLaunchAtLogin else { return }
        updateLaunchAtLogin(newValue)
    }

    private func updateLaunchAtLogin(_ newValue: Bool) {
        do {
            if newValue {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            isUpdatingLaunchAtLogin = true
            launchAtLogin.toggle()
            isUpdatingLaunchAtLogin = false
        }
    }

    func resetAll() {
        themePreference = .system
        languagePreference = .system
        colorSchemePreference = .systemBlue
        ringSource = .combined
        showBuiltInDisplays = true
        displayModuleVisible = true
        displayBrightnessControlEnabled = true
        displayVolumeControlEnabled = true
        displayContrastControlEnabled = false
        displayAvailabilityHintsEnabled = true
        displayNativeOSDEnabled = true
        displaySoftwareDimmingEnabled = true
        brightnessKeyStepPercent = 5
        codexRefreshIntervalMinutes = 5
        updateChecksEnabled = true
        brightnessKeyInterceptionEnabled = true
        mouseControlEnabled = false
        mouseDPIOnDemandEnabled = true
        mouseDPI = 1600
        mouseMiddleAction = .passThrough
        mouseBackAction = .paste
        mouseForwardAction = .launchpad
        mouseGestureAction = .passThrough
        lockScreenPoliciesEnabled = false
        lockScreenRequirePassword = true
        lockScreenPolicies = []
        visibleKinds = Set(MonitorKind.allCases).subtracting([.storage, .network])
        enabledMetrics = [:]
    }
}

private enum Keys {
    static let themePreference = "settings.themePreference"
    static let languagePreference = "settings.languagePreference"
    static let colorSchemePreference = "settings.colorSchemePreference"
    static let ringSource = "settings.ringSource"
    static let displayModuleVisible = "settings.display.moduleVisible"
    static let showBuiltInDisplays = "settings.display.showBuiltInDisplays"
    static let displayBrightnessControlEnabled = "settings.display.brightnessControlEnabled"
    static let displayVolumeControlEnabled = "settings.display.volumeControlEnabled"
    static let displayContrastControlEnabled = "settings.display.contrastControlEnabled"
    static let displayAvailabilityHintsEnabled = "settings.display.availabilityHintsEnabled"
    static let displayNativeOSDEnabled = "settings.display.nativeOSDEnabled"
    static let displaySoftwareDimmingEnabled = "settings.display.softwareDimmingEnabled"
    static let brightnessKeyStepPercent = "settings.display.brightnessKeyStepPercent"
    static let codexRefreshIntervalMinutes = "settings.codexRefreshIntervalMinutes"
    static let updateChecksEnabled = "settings.updateChecksEnabled"
    static let brightnessKeyInterceptionEnabled = "settings.brightnessKeyInterceptionEnabled"
    static let mouseControlEnabled = "settings.mouse.controlEnabled"
    static let mouseDPIOnDemandEnabled = "settings.mouse.dpiOnDemandEnabled"
    static let mouseDPI = "settings.mouse.dpi"
    static let mouseMiddleAction = "settings.mouse.action.middle"
    static let mouseBackAction = "settings.mouse.action.back"
    static let mouseForwardAction = "settings.mouse.action.forward"
    static let mouseGestureAction = "settings.mouse.action.gesture"
    static let lockScreenPoliciesEnabled = "settings.lockScreen.policiesEnabled"
    static let lockScreenRequirePassword = "settings.lockScreen.requirePassword"
    static let lockScreenPolicies = "settings.lockScreen.policies"
    static let lockScreenBaseline = "settings.lockScreen.baseline"
    static let visibleKinds = "settings.visibleKinds"
    static let codexVisibilityMigrated = "settings.codexVisibilityMigrated"
    static let enabledMetricsPrefix = "settings.enabledMetrics."
}
