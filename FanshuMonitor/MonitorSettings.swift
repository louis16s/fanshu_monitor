import Combine
import Foundation
import OSLog
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
    case rose
    case aurora

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemBlue:
            String(localized: "color-scheme.system-blue")
        case .graphite:
            String(localized: "color-scheme.graphite")
        case .rose:
            String(localized: "color-scheme.rose")
        case .aurora:
            String(localized: "color-scheme.aurora")
        }
    }

    var previewColors: [Color] {
        switch self {
        case .systemBlue:
            [Color(hex: 0xD27A4A), Color(hex: 0x5D8CF0), Color(hex: 0x42A39A), Color(hex: 0x8B5CF6)]
        case .graphite:
            [Color(hex: 0xC2410C), Color(hex: 0x475569), Color(hex: 0x0D9488), Color(hex: 0xBE185D)]
        case .rose:
            [Color(hex: 0xE11D48), Color(hex: 0x7C3AED), Color(hex: 0x0891B2), Color(hex: 0xF59E0B)]
        case .aurora:
            [Color(hex: 0xF97316), Color(hex: 0x06B6D4), Color(hex: 0x22C55E), Color(hex: 0xA855F7)]
        }
    }

    static func migratedValue(_ rawValue: String?) -> Self {
        switch rawValue {
        case "teal": .aurora
        case "nightVoyage": .systemBlue
        default: rawValue.flatMap(Self.init(rawValue:)) ?? .systemBlue
        }
    }
}

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            String(localized: "language.system")
        case .simplifiedChinese:
            String(localized: "language.chinese")
        case .english:
            String(localized: "language.english")
        }
    }

    var locale: Locale? {
        switch self {
        case .system:
            nil
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        case .english:
            Locale(identifier: "en")
        }
    }
}

enum CodexHeaderDetailPreference: String, CaseIterable, Identifiable {
    case plan
    case remaining

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan:
            String(localized: "settings.codex-header.plan")
        case .remaining:
            String(localized: "settings.codex-header.remaining")
        }
    }
}

@MainActor
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
    @Published var displayCapabilitiesEnabled: Bool = true
    @Published var displayNativeOSDEnabled: Bool = true
    @Published var displaySoftwareDimmingEnabled: Bool = true
    @Published var brightnessKeyStepPercent: Double = 5
    @Published var codexRefreshIntervalMinutes: Double = 5
    @Published var codexHeaderDetailPreference: CodexHeaderDetailPreference = .plan
    @Published var updateChecksEnabled: Bool = true
    @Published var brightnessKeyInterceptionEnabled: Bool = true
    @Published var mouseControlEnabled: Bool = false
    @Published var mouseDPIOnDemandEnabled: Bool = true
    @Published var mouseDPI: Double = 1600
    @Published var mouseMiddleAction: MouseButtonAction = .passThrough
    @Published var mouseBackAction: MouseButtonAction = .paste
    @Published var mouseForwardAction: MouseButtonAction = .launchpad
    @Published var mouseGestureAction: MouseButtonAction = .passThrough
    @Published private(set) var mouseCustomShortcuts: [MouseButtonSlot: MouseKeyboardShortcut] = [:]
    @Published var lockScreenPoliciesEnabled: Bool = false
    @Published private(set) var lockScreenPolicies: [LockScreenPolicy] = []
    @Published private(set) var visibleKinds: Set<MonitorKind> = []
    @Published private(set) var enabledMetrics: [MonitorKind: Set<MetricID>] = [:]

    static let maximumEnabledMetricsPerKind = 4
    static let maximumLockScreenPolicies = 4

    static func enabledMetricLimit(for kind: MonitorKind) -> Int? {
        switch kind {
        case .battery, .codex:
            nil
        default:
            maximumEnabledMetricsPerKind
        }
    }

    let defaults: UserDefaults
    var isUpdatingLaunchAtLogin = false
    var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let themeRawValue = defaults.string(forKey: Keys.themePreference) ?? AppThemePreference.system.rawValue
        themePreference = AppThemePreference(rawValue: themeRawValue) ?? .system

        let languageRawValue = defaults.string(forKey: Keys.languagePreference) ?? AppLanguagePreference.system.rawValue
        languagePreference = AppLanguagePreference(rawValue: languageRawValue) ?? .system

        colorSchemePreference = MonitorColorSchemePreference.migratedValue(
            defaults.string(forKey: Keys.colorSchemePreference)
        )

        let ringSourceRawValue = defaults.string(forKey: Keys.ringSource) ?? HaloRingSource.combined.rawValue
        ringSource = HaloRingSource(rawValue: ringSourceRawValue) ?? .combined

        showBuiltInDisplays = defaults.object(forKey: Keys.showBuiltInDisplays) as? Bool ?? true
        displayModuleVisible = defaults.object(forKey: Keys.displayModuleVisible) as? Bool ?? true
        displayBrightnessControlEnabled = defaults.object(forKey: Keys.displayBrightnessControlEnabled) as? Bool ?? true
        displayVolumeControlEnabled = defaults.object(forKey: Keys.displayVolumeControlEnabled) as? Bool ?? true
        displayContrastControlEnabled = defaults.object(forKey: Keys.displayContrastControlEnabled) as? Bool ?? false
        displayAvailabilityHintsEnabled = defaults.object(forKey: Keys.displayAvailabilityHintsEnabled) as? Bool ?? true
        displayCapabilitiesEnabled = defaults.object(forKey: Keys.displayCapabilitiesEnabled) as? Bool ?? true
        displayNativeOSDEnabled = defaults.object(forKey: Keys.displayNativeOSDEnabled) as? Bool ?? true
        displaySoftwareDimmingEnabled = defaults.object(forKey: Keys.displaySoftwareDimmingEnabled) as? Bool ?? true
        brightnessKeyStepPercent = defaults.object(forKey: Keys.brightnessKeyStepPercent) as? Double ?? 5
        codexRefreshIntervalMinutes = defaults.object(forKey: Keys.codexRefreshIntervalMinutes) as? Double ?? 5
        codexHeaderDetailPreference = CodexHeaderDetailPreference(
            rawValue: defaults.string(forKey: Keys.codexHeaderDetailPreference) ?? ""
        ) ?? .plan
        updateChecksEnabled = defaults.object(forKey: Keys.updateChecksEnabled) as? Bool ?? true
        brightnessKeyInterceptionEnabled = defaults.object(forKey: Keys.brightnessKeyInterceptionEnabled) as? Bool ?? true
        mouseControlEnabled = defaults.object(forKey: Keys.mouseControlEnabled) as? Bool ?? false
        mouseDPIOnDemandEnabled = defaults.object(forKey: Keys.mouseDPIOnDemandEnabled) as? Bool ?? true
        mouseDPI = defaults.object(forKey: Keys.mouseDPI) as? Double ?? 1600
        mouseMiddleAction = MouseButtonAction(rawValue: defaults.string(forKey: Keys.mouseMiddleAction) ?? "") ?? .passThrough
        mouseBackAction = MouseButtonAction(rawValue: defaults.string(forKey: Keys.mouseBackAction) ?? "") ?? .paste
        mouseForwardAction = MouseButtonAction(rawValue: defaults.string(forKey: Keys.mouseForwardAction) ?? "") ?? .launchpad
        mouseGestureAction = MouseButtonAction(rawValue: defaults.string(forKey: Keys.mouseGestureAction) ?? "") ?? .passThrough
        if let data = defaults.data(forKey: Keys.mouseCustomShortcuts),
           let storedShortcuts = PreferencesCodec.decode(
               [String: MouseKeyboardShortcut].self,
               from: data,
               key: Keys.mouseCustomShortcuts
           ) {
            mouseCustomShortcuts = Dictionary(
                uniqueKeysWithValues: storedShortcuts.compactMap { rawSlot, shortcut in
                    MouseButtonSlot(rawValue: rawSlot).map { ($0, shortcut) }
                }
            )
        }
        lockScreenPoliciesEnabled = defaults.object(forKey: Keys.lockScreenPoliciesEnabled) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.lockScreenPolicies),
           let policies = PreferencesCodec.decode(
               [LockScreenPolicy].self,
               from: data,
               key: Keys.lockScreenPolicies
           ) {
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
            visibleKinds = Set(MonitorKind.allCases).subtracting([.network])
            defaults.set(true, forKey: Keys.codexVisibilityMigrated)
        }

        var loadedMetrics: [MonitorKind: Set<MetricID>] = [:]
        for kind in MonitorKind.allCases {
            let key = Keys.enabledMetricsPrefix + kind.rawValue
            if let stored = defaults.array(forKey: key) as? [String] {
                let migrated = migrateMetrics(stored, for: kind)
                loadedMetrics[kind] = Set(migrated)
            }
        }
        if !defaults.bool(forKey: Keys.codexActiveTasksMetricMigrated) {
            loadedMetrics[.codex, default: defaultMetricIds(for: .codex)].insert(.activeTasks)
            defaults.set(true, forKey: Keys.codexActiveTasksMetricMigrated)
        }
        enabledMetrics = loadedMetrics

        let launchAtLoginDesired = defaults.object(forKey: Keys.launchAtLoginDesired) as? Bool
        launchAtLogin = SMAppService.mainApp.status == .enabled

        setupBindings()
        if launchAtLoginDesired == true, !launchAtLogin {
            updateLaunchAtLogin(true)
        }
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

    func refreshLaunchAtLoginStatus() {
        let isEnabled = SMAppService.mainApp.status == .enabled
        guard launchAtLogin != isEnabled else { return }
        isUpdatingLaunchAtLogin = true
        launchAtLogin = isEnabled
        isUpdatingLaunchAtLogin = false
    }

    func isMetricEnabled(_ id: MetricID, for kind: MonitorKind) -> Bool {
        if let stored = enabledMetrics[kind] {
            return stored.contains(id)
        }
        return kind.availableMetrics.first(where: { $0.id == id })?.isDefault ?? false
    }

    func canEnableMetric(_ id: MetricID, for kind: MonitorKind) -> Bool {
        guard kind.availableMetrics.contains(where: { $0.id == id }) else { return false }
        let current = enabledMetrics[kind] ?? defaultMetricIds(for: kind)
        guard let limit = Self.enabledMetricLimit(for: kind) else { return true }
        return current.contains(id) || current.count < limit
    }

    func setMetric(_ id: MetricID, enabled: Bool, for kind: MonitorKind) {
        guard kind.availableMetrics.contains(where: { $0.id == id }) else { return }
        var current = enabledMetrics[kind] ?? defaultMetricIds(for: kind)
        if enabled {
            if let limit = Self.enabledMetricLimit(for: kind) {
                guard current.contains(id) || current.count < limit else { return }
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

    func mouseMapping(for slot: MouseButtonSlot) -> MouseButtonMapping {
        MouseButtonMapping(
            action: mouseAction(for: slot),
            shortcut: mouseCustomShortcuts[slot]
        )
    }

    func setMouseCustomShortcut(_ shortcut: MouseKeyboardShortcut?, for slot: MouseButtonSlot) {
        var updated = mouseCustomShortcuts
        updated[slot] = shortcut
        mouseCustomShortcuts = updated
    }

    func addLockScreenPolicy() {
        guard lockScreenPolicies.count < Self.maximumLockScreenPolicies else { return }
        let defaultName = nextLockScreenPolicyName()
        let newPolicy: LockScreenPolicy
        if let last = lockScreenPolicies.last {
            let startMinutes = last.endMinutes < 1_440 ? last.endMinutes : 0
            newPolicy = LockScreenPolicy(
                name: defaultName,
                dayScope: last.dayScope,
                powerCondition: last.powerCondition,
                startMinutes: startMinutes,
                endMinutes: startMinutes == 0 ? 60 : 1_440,
                idleMinutes: last.idleMinutes
            )
        } else {
            newPolicy = LockScreenPolicy(name: defaultName)
        }
        lockScreenPolicies.append(newPolicy)
    }

    func setLockScreenPoliciesEnabled(_ enabled: Bool) {
        lockScreenPoliciesEnabled = enabled
    }

    func updateLockScreenPolicy(_ policy: LockScreenPolicy) {
        guard let index = lockScreenPolicies.firstIndex(where: { $0.id == policy.id }) else { return }
        var normalizedPolicy = policy
        normalizedPolicy.normalize()
        lockScreenPolicies[index] = normalizedPolicy
    }

    func updateLockScreenPolicy(
        id: LockScreenPolicy.ID,
        _ update: (inout LockScreenPolicy) -> Void
    ) {
        guard let index = lockScreenPolicies.firstIndex(where: { $0.id == id }) else { return }
        var policy = lockScreenPolicies[index]
        update(&policy)
        policy.normalize()
        guard policy != lockScreenPolicies[index] else { return }
        lockScreenPolicies[index] = policy
    }

    func removeLockScreenPolicy(id: LockScreenPolicy.ID) {
        lockScreenPolicies.removeAll { $0.id == id }
    }

    func moveLockScreenPolicy(id: LockScreenPolicy.ID, to targetID: LockScreenPolicy.ID) {
        guard id != targetID,
              let sourceIndex = lockScreenPolicies.firstIndex(where: { $0.id == id }),
              let targetIndex = lockScreenPolicies.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        let policy = lockScreenPolicies.remove(at: sourceIndex)
        lockScreenPolicies.insert(policy, at: min(targetIndex, lockScreenPolicies.endIndex))
    }

    private func nextLockScreenPolicyName() -> String {
        let existingNames = Set(
            lockScreenPolicies.enumerated().map { index, policy in
                policy.name.isEmpty ? "时间段 \(index + 1)" : policy.name
            }
        )
        let availableNumber = (1...Self.maximumLockScreenPolicies).first {
            !existingNames.contains("时间段 \($0)")
        } ?? (lockScreenPolicies.count + 1)
        return "时间段 \(availableNumber)"
    }

    var lockScreenBaseline: ScreenSaverLockBaseline? {
        get {
            guard let data = defaults.data(forKey: Keys.lockScreenBaseline) else { return nil }
            return PreferencesCodec.decode(
                ScreenSaverLockBaseline.self,
                from: data,
                key: Keys.lockScreenBaseline
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.lockScreenBaseline)
                return
            }
            if let data = PreferencesCodec.encode(newValue, key: Keys.lockScreenBaseline) {
                defaults.set(data, forKey: Keys.lockScreenBaseline)
            }
        }
    }

    private func migrateMetrics(_ ids: [String], for kind: MonitorKind) -> [MetricID] {
        let mapping: [String: String] = {
            switch kind {
            case .cpu:
                return ["系统": "system", "用户": "user", "闲置": "idle", "温度": "temperature"]
            case .gpu:
                return ["GPU内存": "gpu-memory", "已分配": "allocated", "渲染": "render", "分块": "tiler", "温度": "temperature"]
            case .memory:
                return ["已用": "used", "压力": "pressure", "总量": "total", "App 占用": "app-memory", "缓存": "cached", "已压缩": "compressed"]
            case .network:
                return ["IP 地址": "ipv4", "上传": "upload", "下载": "download", "SSID": "ssid", "IPv4": "ipv4", "IPv6": "ipv6"]
            case .battery:
                return [
                    "输入": "power-flow",
                    "系统": "power-flow",
                    "电池流向": "power-flow",
                    "功率分流指标": "power-flow",
                    "adapter-input": "power-flow",
                    "system-load": "power-flow",
                    "battery-flow": "power-flow",
                    "充电功率": "charging-power",
                    "健康度": "health",
                    "循环数": "cycle-count",
                    "温度": "temperature",
                    "适配器": "adapter",
                    "功耗": "power"
                ]
            case .codex:
                return [
                    "5H": "five-hour",
                    "一周": "weekly",
                    "下次刷新": "five-hour-reset",
                    "状态": "weekly-reset",
                    "5H刷新": "five-hour-reset",
                    "周刷新": "weekly-reset",
                    "重置卡": "reset-credits",
                    "套餐": "plan",
                    "运行中的任务": "active-tasks",
                    "进行中任务": "active-tasks",
                    "活动任务": "active-tasks",
                    "next-reset": "five-hour-reset",
                    "status": "weekly-reset"
                ]
            }
        }()

        var result = Set<MetricID>()
        for id in ids {
            if let mapped = mapping[id] {
                result.insert(MetricID(rawValue: mapped))
            } else {
                result.insert(MetricID(rawValue: id))
            }
        }

        let filtered = kind.availableMetrics
            .map(\.id)
            .filter(result.contains)

        if filtered.isEmpty {
            return Array(defaultMetricIds(for: kind))
        }

        guard let limit = Self.enabledMetricLimit(for: kind) else {
            return filtered
        }
        return Array(filtered.prefix(limit))
    }

    private func defaultMetricIds(for kind: MonitorKind) -> Set<MetricID> {
        Set(kind.availableMetrics.filter { $0.isDefault }.map { $0.id })
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
        displayCapabilitiesEnabled = true
        displayNativeOSDEnabled = true
        displaySoftwareDimmingEnabled = true
        brightnessKeyStepPercent = 5
        codexRefreshIntervalMinutes = 5
        codexHeaderDetailPreference = .plan
        updateChecksEnabled = true
        brightnessKeyInterceptionEnabled = true
        mouseControlEnabled = false
        mouseDPIOnDemandEnabled = true
        mouseDPI = 1600
        mouseMiddleAction = .passThrough
        mouseBackAction = .paste
        mouseForwardAction = .launchpad
        mouseGestureAction = .passThrough
        mouseCustomShortcuts = [:]
        lockScreenPoliciesEnabled = false
        lockScreenPolicies = []
        visibleKinds = Set(MonitorKind.allCases).subtracting([.network])
        for kind in MonitorKind.allCases {
            defaults.removeObject(forKey: Keys.enabledMetricsPrefix + kind.rawValue)
        }
        enabledMetrics = [:]
    }
}

enum Keys {
    static let launchAtLoginDesired = "settings.launchAtLoginDesired"
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
    static let displayCapabilitiesEnabled = "settings.display.capabilitiesEnabled"
    static let displayNativeOSDEnabled = "settings.display.nativeOSDEnabled"
    static let displaySoftwareDimmingEnabled = "settings.display.softwareDimmingEnabled"
    static let brightnessKeyStepPercent = "settings.display.brightnessKeyStepPercent"
    static let codexRefreshIntervalMinutes = "settings.codexRefreshIntervalMinutes"
    static let codexHeaderDetailPreference = "settings.codex.headerDetailPreference"
    static let updateChecksEnabled = "settings.updateChecksEnabled"
    static let brightnessKeyInterceptionEnabled = "settings.brightnessKeyInterceptionEnabled"
    static let mouseControlEnabled = "settings.mouse.controlEnabled"
    static let mouseDPIOnDemandEnabled = "settings.mouse.dpiOnDemandEnabled"
    static let mouseDPI = "settings.mouse.dpi"
    static let mouseMiddleAction = "settings.mouse.action.middle"
    static let mouseBackAction = "settings.mouse.action.back"
    static let mouseForwardAction = "settings.mouse.action.forward"
    static let mouseGestureAction = "settings.mouse.action.gesture"
    static let mouseCustomShortcuts = "settings.mouse.customShortcuts"
    static let lockScreenPoliciesEnabled = "settings.lockScreen.policiesEnabled"
    static let lockScreenPolicies = "settings.lockScreen.policies"
    static let lockScreenBaseline = "settings.lockScreen.baseline"
    static let visibleKinds = "settings.visibleKinds"
    static let codexVisibilityMigrated = "settings.codexVisibilityMigrated"
    static let codexActiveTasksMetricMigrated = "settings.codex.activeTasksMetricMigrated"
    static let enabledMetricsPrefix = "settings.enabledMetrics."
}
