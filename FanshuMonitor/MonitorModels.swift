import Foundation
import SwiftUI
import Combine
import OSLog

enum HaloRingSource: String, CaseIterable, Identifiable {
    case combined
    case cpu
    case gpu
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .combined: String(localized: "ring-source.combined")
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: String(localized: "ring-source.memory")
        }
    }
}

enum MemoryPressureLevel {
    case normal
    case warning
    case critical
    case unknown
}

enum MonitorSeverity {
    case calm
    case warning
    case critical

    var title: String {
        switch self {
        case .calm:
            String(localized: "severity.calm")
        case .warning:
            String(localized: "severity.warning")
        case .critical:
            String(localized: "severity.critical")
        }
    }
}

enum MonitorKind: String, CaseIterable, Identifiable {
    case cpu
    case gpu
    case memory
    case storage
    case network
    case battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:
            String(localized: "kind.cpu")
        case .gpu:
            String(localized: "kind.gpu")
        case .memory:
            String(localized: "kind.memory")
        case .storage:
            String(localized: "kind.storage")
        case .network:
            String(localized: "kind.network")
        case .battery:
            String(localized: "kind.battery")
        }
    }

    var symbol: String {
        switch self {
        case .cpu:
            "cpu"
        case .gpu:
            "display"
        case .memory:
            "memorychip"
        case .storage:
            "internaldrive"
        case .network:
            "network"
        case .battery:
            "powerplug"
        }
    }

    var availableMetrics: [MetricSwitch] {
        switch self {
        case .cpu:
            return [
                MetricSwitch(id: "system", title: String(localized: "metric.cpu.system"), isDefault: true),
                MetricSwitch(id: "user", title: String(localized: "metric.cpu.user"), isDefault: true),
                MetricSwitch(id: "idle", title: String(localized: "metric.cpu.idle"), isDefault: true),
                MetricSwitch(id: "temperature", title: String(localized: "metric.cpu.temperature"), isDefault: true),
            ]
        case .gpu:
            return [
                MetricSwitch(id: "gpu-memory", title: String(localized: "metric.gpu.gpu-memory"), isDefault: true),
                MetricSwitch(id: "allocated", title: String(localized: "metric.gpu.allocated"), isDefault: true),
                MetricSwitch(id: "render", title: String(localized: "metric.gpu.render"), isDefault: true),
                MetricSwitch(id: "tiler", title: String(localized: "metric.gpu.tiler"), isDefault: true),
            ]
        case .memory:
            return [
                MetricSwitch(id: "used", title: String(localized: "metric.memory.used"), isDefault: true),
                MetricSwitch(id: "pressure", title: String(localized: "metric.memory.pressure"), isDefault: true),
                MetricSwitch(id: "swap-used", title: String(localized: "metric.memory.swap-used"), isDefault: true),
                MetricSwitch(id: "app-memory", title: "应用占用", isDefault: true),
                MetricSwitch(id: "cached", title: "缓存", isDefault: false),
                MetricSwitch(id: "compressed", title: "压缩", isDefault: false),
                MetricSwitch(id: "total", title: String(localized: "metric.memory.total"), isDefault: false),
            ]
        case .storage:
            return [
                MetricSwitch(id: "used", title: String(localized: "metric.storage.used"), isDefault: true),
                MetricSwitch(id: "free", title: String(localized: "metric.storage.free"), isDefault: true),
                MetricSwitch(id: "total", title: String(localized: "metric.storage.total"), isDefault: true),
            ]
        case .network:
            return [
                MetricSwitch(id: "ssid", title: "无线名称", isDefault: true),
                MetricSwitch(id: "ipv4", title: "IPv4 地址", isDefault: true),
                MetricSwitch(id: "ipv6", title: "IPv6 地址", isDefault: true),
                MetricSwitch(id: "upload", title: "上传", isDefault: true),
                MetricSwitch(id: "download", title: "下载", isDefault: true),
            ]
        case .battery:
            return [
                MetricSwitch(id: "charging-power", title: String(localized: "metric.battery.charging-power"), isDefault: true),
                MetricSwitch(id: "adapter", title: String(localized: "metric.battery.adapter"), isDefault: true),
                MetricSwitch(id: "health", title: String(localized: "metric.battery.health"), isDefault: true),
                MetricSwitch(id: "cycle-count", title: String(localized: "metric.battery.cycle-count"), isDefault: true),
                MetricSwitch(id: "temperature", title: String(localized: "metric.battery.temperature"), isDefault: false),
            ]
        }
    }
}

struct MetricSwitch: Identifiable, Hashable {
    let id: String
    let title: String
    let isDefault: Bool
}

struct MonitorMetric: Identifiable {
    let name: String
    let value: String

    var id: String { name }
}

struct MonitorModule: Identifiable {
    let kind: MonitorKind
    var context: String? = nil
    var value: Double
    var summary: String
    var metrics: [MonitorMetric]
    var samples: [Double]
    var pressure: MemoryPressureLevel? = nil

    var id: MonitorKind { kind }

    var severity: MonitorSeverity {
        switch kind {
        case .cpu, .gpu, .memory, .storage:
            if value >= MonitorConstants.criticalThreshold { return .critical }
            if value >= MonitorConstants.warningThreshold { return .warning }
            return .calm
        case .network:
            if value >= MonitorConstants.networkWarningThreshold { return .warning }
            return .calm
        case .battery:
            if metrics.first(where: { $0.name == "type" })?.value == "ac-power" {
                return .calm
            }
            if value <= MonitorConstants.batteryCriticalThreshold { return .critical }
            if value <= MonitorConstants.batteryWarningThreshold { return .warning }
            return .calm
        }
    }

    nonisolated static func placeholder(kind: MonitorKind) -> MonitorModule {
        MonitorModule(
            kind: kind,
            context: nil,
            value: 0,
            summary: "--",
            metrics: [
                MonitorMetric(name: "current", value: "--"),
                MonitorMetric(name: "average", value: "--"),
                MonitorMetric(name: "peak", value: "--")
            ],
            samples: Array(repeating: 0, count: 28)
        )
    }
}

final class MonitorStore: ObservableObject {
    let settings: MonitorSettings

    @Published private(set) var modules: [MonitorModule]
    @Published var selectedKind: MonitorKind = .cpu
    @Published private(set) var menuBarFrame = 0
    @Published private(set) var displayedComputeLoad = 0.0
    @Published var isPanelVisible = false
    #if DISPLAY_CONTROL
    let displayController = DisplayControlController()
    private var brightnessKeyEventTap: BrightnessKeyEventTap?
    #endif

    private var allModules: [MonitorModule]
    private let refreshSchedule = MonitorRefreshSchedule()
    private var timerCancellable: AnyCancellable?
    private var animationTimerCancellable: AnyCancellable?
    private let sampler = SystemMonitorSampler()
    private var cancellables: Set<AnyCancellable> = []
    private var menuBarTargetComputeLoad = 0.0
    private var framesSinceLastMenuBarTargetUpdate = MonitorConstants.menuBarLoadUpdateFrameInterval

    init() {
        let settings = MonitorSettings()
        let initialModules = MonitorKind.allCases.map(MonitorModule.placeholder)
        self.settings = settings
        allModules = initialModules
        modules = initialModules.filter { settings.isVisible($0.kind) }
        advance(kinds: settings.visibleKinds)
        refreshSchedule.markRefreshed(settings.visibleKinds, at: Date())
        #if DISPLAY_CONTROL
        displayController.startAutomaticRefresh()
        displayController.refreshSynchronously()
        brightnessKeyEventTap = BrightnessKeyEventTap(settings: settings, displayController: displayController)
        brightnessKeyEventTap?.requestInitialAccessibilityPermissionIfNeeded()
        brightnessKeyEventTap?.start()
        #endif
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.modules = self.visibleModules(from: self.allModules)
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
        timerCancellable = Timer.publish(every: refreshSchedule.tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                AppLogger.ui.debug("Timer tick triggered")
                self?.advance()
                self?.retryBrightnessKeyTapIfNeeded()
            }
        animationTimerCancellable = Timer.publish(every: MonitorConstants.animationInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.advanceAnimation()
            }
    }

    deinit {
        timerCancellable?.cancel()
        animationTimerCancellable?.cancel()
        cancellables.removeAll()
    }

    var selectedModule: MonitorModule {
        allModules.first { $0.kind == selectedKind }
            ?? allModules.first
            ?? MonitorModule.placeholder(kind: selectedKind)
    }

    var combinedComputeLoad: Double {
        switch settings.ringSource {
        case .combined:
            let cpuValue = allModules.first { $0.kind == .cpu }?.value ?? 0
            let gpuValue = allModules.first { $0.kind == .gpu }?.value ?? 0
            let memoryPressure = allModules.first { $0.kind == .memory }?.pressure ?? .unknown
            return ComputeLoadModel.combined(
                cpuValue: cpuValue,
                gpuValue: gpuValue,
                memoryPressure: memoryPressure
            )
        case .cpu:
            return allModules.first { $0.kind == .cpu }?.value ?? 0
        case .gpu:
            return allModules.first { $0.kind == .gpu }?.value ?? 0
        case .memory:
            return allModules.first { $0.kind == .memory }?.value ?? 0
        }
    }

    var haloRingLoadLevel: MenuBarComputeLoadLevel {
        switch settings.ringSource {
        case .combined, .cpu, .gpu:
            return ComputeLoadModel.loadLevel(for: combinedComputeLoad)
        case .memory:
            let pressure = allModules.first { $0.kind == .memory }?.pressure ?? .unknown
            switch pressure {
            case .normal: return .idle
            case .warning: return .busy
            case .critical: return .stressed
            case .unknown: return .working
            }
        }
    }

    private func advance() {
        let kinds = refreshSchedule.dueKinds(
            at: Date(),
            visibleKinds: settings.visibleKinds,
            panelVisible: isPanelVisible
        )
        guard !kinds.isEmpty else {
            return
        }
        let kindNames = kinds.map { $0.rawValue }.joined(separator: ", ")
        AppLogger.ui.debug("Advancing modules: \(kindNames, privacy: .public)")
        advance(kinds: kinds)
    }

    private func advance(kinds: some Sequence<MonitorKind>) {
        let result = sampler.sample(kinds: kinds, previousModules: allModules)
        switch result {
        case .success(let snapshot):
            allModules = snapshot.modules
            modules = visibleModules(from: allModules)
        case .failure(let error):
            AppLogger.sampler.error("Sampling failed: \(error.description, privacy: .public)")
        }
    }

    private func advanceAnimation() {
        guard isPanelVisible || menuBarFrame % 4 == 0 else {
            menuBarFrame = (menuBarFrame + 1) % 48
            return
        }
        menuBarFrame = (menuBarFrame + 1) % 48
        updateMenuBarTargetComputeLoadIfNeeded()
        displayedComputeLoad = ComputeLoadModel.smoothedDisplayValue(
            current: displayedComputeLoad,
            target: menuBarTargetComputeLoad
        )
    }

    private func retryBrightnessKeyTapIfNeeded() {
        #if DISPLAY_CONTROL
        if settings.brightnessKeyInterceptionEnabled {
            brightnessKeyEventTap?.start()
        } else {
            brightnessKeyEventTap?.stop()
        }
        #endif
    }

    private func updateMenuBarTargetComputeLoadIfNeeded() {
        framesSinceLastMenuBarTargetUpdate += 1
        guard framesSinceLastMenuBarTargetUpdate >= MonitorConstants.menuBarLoadUpdateFrameInterval else {
            return
        }

        framesSinceLastMenuBarTargetUpdate = 0
        let currentLoad = combinedComputeLoad
        guard ComputeLoadModel.shouldUpdateMenuBarTarget(
            currentTarget: menuBarTargetComputeLoad,
            nextTarget: currentLoad
        ) else {
            return
        }

        menuBarTargetComputeLoad = currentLoad
    }

    private func visibleModules(from modules: [MonitorModule]) -> [MonitorModule] {
        modules.filter { settings.isVisible($0.kind) }
    }

    func refreshNow() {
        refreshSchedule.reset()
        advance(kinds: settings.visibleKinds)
        #if DISPLAY_CONTROL
        displayController.refreshNow()
        #endif
    }

    func moduleDetailsText() -> String {
        modules.map { module in
            let metrics = module.metrics.map { "\($0.name): \($0.value)" }.joined(separator: ", ")
            return "\(module.kind.title): \(module.summary) \(metrics)"
        }
        .joined(separator: "\n")
    }
}

enum ComputeLoadModel {
    static func combined(
        cpuValue: Double,
        gpuValue: Double,
        memoryPressure: MemoryPressureLevel = .normal
    ) -> Double {
        let cpu = min(100, max(0, cpuValue))
        let gpu = min(100, max(0, gpuValue))
        let memory = memoryPressureScore(memoryPressure)
        return cpu * 0.4 + gpu * 0.4 + memory * 0.2
    }

    static func memoryPressureScore(_ pressure: MemoryPressureLevel) -> Double {
        switch pressure {
        case .normal:
            return 0
        case .warning:
            return 70
        case .critical:
            return 100
        case .unknown:
            return 0
        }
    }

    static func loadLevel(for load: Double) -> MenuBarComputeLoadLevel {
        switch load {
        case ..<35: return .idle
        case ..<65: return .working
        case ..<85: return .busy
        default: return .stressed
        }
    }

    static func smoothedDisplayValue(
        current: Double,
        target: Double,
        maxStep: Double = MonitorConstants.menuBarLoadSmoothStep
    ) -> Double {
        let clampedCurrent = min(100, max(0, current))
        let clampedTarget = min(100, max(0, target))
        let delta = clampedTarget - clampedCurrent

        if abs(delta) <= maxStep {
            return clampedTarget
        }

        return clampedCurrent + (delta > 0 ? maxStep : -maxStep)
    }

    static func shouldUpdateMenuBarTarget(
        currentTarget: Double,
        nextTarget: Double,
        threshold: Double = MonitorConstants.menuBarLoadChangeThreshold
    ) -> Bool {
        abs(min(100, max(0, nextTarget)) - min(100, max(0, currentTarget))) >= threshold
    }
}

final class MonitorRefreshSchedule {
    let tickInterval: TimeInterval

    private let intervals: [MonitorKind: TimeInterval]
    private var lastRefreshDates: [MonitorKind: Date] = [:]

    init(
        tickInterval: TimeInterval = 1,
        intervals: [MonitorKind: TimeInterval] = [
            .cpu: 1, .gpu: 2, .memory: 3,
            .storage: 10, .network: 1, .battery: 5
        ]
    ) {
        self.tickInterval = tickInterval
        self.intervals = intervals
    }

    func dueKinds(at date: Date, visibleKinds: Set<MonitorKind>? = nil, panelVisible: Bool = true) -> [MonitorKind] {
        let kinds = visibleKinds ?? Set(MonitorKind.allCases)
        let dueKinds = MonitorKind.allCases.filter { kind in
            guard kinds.contains(kind) else { return false }
            let interval = effectiveInterval(for: kind, panelVisible: panelVisible)
            guard let lastRefreshDate = lastRefreshDates[kind] else {
                return true
            }

            return date.timeIntervalSince(lastRefreshDate) >= interval
        }
        markRefreshed(dueKinds, at: date)
        return dueKinds
    }

    func reset() {
        lastRefreshDates.removeAll()
    }

    func markRefreshed(_ kinds: some Sequence<MonitorKind>, at date: Date) {
        for kind in kinds {
            lastRefreshDates[kind] = date
        }
    }

    private func effectiveInterval(for kind: MonitorKind, panelVisible: Bool) -> TimeInterval {
        let base = intervals[kind] ?? tickInterval
        guard !panelVisible else { return base }
        switch kind {
        case .cpu, .memory:
            return max(base, 5)
        case .gpu, .network, .battery:
            return max(base, 15)
        case .storage:
            return max(base, 60)
        }
    }
}
