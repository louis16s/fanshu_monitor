import Foundation

nonisolated enum HaloRingSource: String, CaseIterable, Identifiable {
    case combined
    case cpu
    case gpu
    case memory
    case battery
    case codex
    case codexWeekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .combined: String(localized: "ring-source.combined")
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: String(localized: "ring-source.memory")
        case .battery: String(localized: "kind.battery")
        case .codex: "Codex 5H"
        case .codexWeekly: "Codex Week"
        }
    }
}

nonisolated enum MemoryPressureLevel: Equatable, Sendable {
    case normal
    case warning
    case critical
    case unknown
}

nonisolated enum MonitorSeverity {
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

nonisolated enum MonitorKind: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case gpu
    case memory
    case battery
    case codex

    var id: String { rawValue }

    static let settingsOrder: [MonitorKind] = [
        .cpu,
        .gpu,
        .memory,
        .battery,
        .codex,
    ]

    var title: String {
        switch self {
        case .cpu:
            "CPU"
        case .gpu:
            "GPU"
        case .memory:
            String(localized: "kind.memory")
        case .battery:
            String(localized: "kind.battery")
        case .codex:
            "Codex"
        }
    }

    var panelTitle: String {
        switch self {
        case .cpu:
            "CPU"
        case .gpu:
            "GPU"
        case .memory:
            "UMA"
        case .battery:
            "Power"
        case .codex:
            "Codex Limits"
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
        case .battery:
            "powerplug"
        case .codex:
            "terminal"
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
                MetricSwitch(id: "tiler", title: String(localized: "metric.gpu.tiler"), isDefault: false),
                MetricSwitch(
                    id: "temperature",
                    title: String(localized: "metric.gpu.temperature"),
                    subtitle: String(localized: "metric.gpu.temperature.m5-unavailable"),
                    isDefault: false
                ),
            ]
        case .memory:
            return [
                MetricSwitch(id: "used", title: String(localized: "metric.memory.used"), isDefault: true),
                MetricSwitch(id: "pressure", title: String(localized: "metric.memory.pressure"), isDefault: true),
                MetricSwitch(id: "compressed", title: "已压缩", isDefault: true),
                MetricSwitch(id: "app-memory", title: "应用占用", isDefault: true),
                MetricSwitch(id: "cached", title: "缓存", isDefault: false),
                MetricSwitch(id: "total", title: String(localized: "metric.memory.total"), isDefault: false),
            ]
        case .battery:
            return [
                MetricSwitch(id: "power-flow", title: String(localized: "metric.battery.power-flow"), isDefault: false),
                MetricSwitch(id: "charging-power", title: String(localized: "metric.battery.charging-power"), isDefault: true),
                MetricSwitch(id: "adapter", title: String(localized: "metric.battery.adapter"), isDefault: true),
                MetricSwitch(id: "health", title: String(localized: "metric.battery.health"), isDefault: true),
                MetricSwitch(id: "cycle-count", title: String(localized: "metric.battery.cycle-count"), isDefault: true),
                MetricSwitch(id: "temperature", title: String(localized: "metric.battery.temperature"), isDefault: false),
            ]
        case .codex:
            return [
                MetricSwitch(id: "plan", title: String(localized: "metric.codex.plan"), isDefault: false),
                MetricSwitch(id: "five-hour", title: "5H", isDefault: true),
                MetricSwitch(id: "five-hour-reset", title: String(localized: "metric.codex.five-hour-reset"), isDefault: true),
                MetricSwitch(id: "weekly", title: String(localized: "metric.codex.weekly"), isDefault: true),
                MetricSwitch(id: "weekly-reset", title: String(localized: "metric.codex.weekly-reset"), isDefault: false),
                MetricSwitch(id: "active-tasks", title: String(localized: "metric.codex.active-tasks"), isDefault: true),
                MetricSwitch(id: "reset-credits", title: String(localized: "metric.codex.reset-credits"), isDefault: false),
            ]
        }
    }

    var primarySettingsMetrics: [MetricSwitch] {
        let separatelyConfiguredMetricIDs: Set<MetricID>
        switch self {
        case .battery:
            separatelyConfiguredMetricIDs = ["power-flow"]
        case .codex:
            separatelyConfiguredMetricIDs = ["active-tasks"]
        default:
            separatelyConfiguredMetricIDs = []
        }
        return availableMetrics.filter { !separatelyConfiguredMetricIDs.contains($0.id) }
    }
}

nonisolated struct MetricSwitch: Identifiable, Hashable {
    let id: MetricID
    let title: String
    let subtitle: String?
    let isDefault: Bool

    init(id: MetricID, title: String, subtitle: String? = nil, isDefault: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isDefault = isDefault
    }
}

nonisolated struct MonitorMetric: Equatable, Identifiable, Sendable {
    let name: MetricID
    let value: String

    var id: MetricID { name }
}

nonisolated extension MonitorKind {
    static let batteryPowerFlowComponentIDs: Set<MetricID> = [
        "adapter-input",
        "system-load",
        "battery-flow"
    ]

    func resolvedPanelMetricIDs(from enabledIDs: Set<MetricID>) -> Set<MetricID> {
        guard self == .battery, enabledIDs.contains("power-flow") else {
            return enabledIDs
        }
        return enabledIDs.union(Self.batteryPowerFlowComponentIDs)
    }
}

nonisolated struct MonitorModule: Equatable, Identifiable, Sendable {
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
        case .cpu, .gpu, .memory:
            if value >= MonitorConstants.criticalThreshold { return .critical }
            if value >= MonitorConstants.warningThreshold { return .warning }
            return .calm
        case .codex:
            if value >= MonitorConstants.criticalThreshold { return .critical }
            if value >= MonitorConstants.warningThreshold { return .warning }
            return .calm
        case .battery:
            let powerStatus = metrics.first(where: { $0.name == .batteryStatus })?.value
            if powerStatus == "ac-power" || powerStatus == "charging" {
                return .calm
            }
            if value <= MonitorConstants.batteryCriticalThreshold { return .critical }
            if value <= MonitorConstants.batteryWarningThreshold { return .warning }
            return .calm
        }
    }

    nonisolated static func placeholder(kind: MonitorKind) -> MonitorModule {
        let metrics: [MonitorMetric]
        let summary: String
        let pressure: MemoryPressureLevel?

        switch kind {
        case .cpu:
            summary = "0%"
            metrics = [
                MonitorMetric(name: "system", value: "0%"),
                MonitorMetric(name: "user", value: "0%"),
                MonitorMetric(name: "idle", value: "100%"),
                MonitorMetric(name: "temperature", value: "--")
            ]
            pressure = nil
        case .gpu:
            summary = "0%"
            metrics = [
                MonitorMetric(name: "gpu-memory", value: "0 B"),
                MonitorMetric(name: "allocated", value: "0 B"),
                MonitorMetric(name: "render", value: "0%"),
                MonitorMetric(name: "temperature", value: "--"),
                MonitorMetric(name: "tiler", value: "0%")
            ]
            pressure = nil
        case .memory:
            summary = "0%"
            metrics = [
                MonitorMetric(name: "used", value: "0 B"),
                MonitorMetric(name: "pressure", value: "normal"),
                MonitorMetric(name: "compressed", value: "0 B"),
                MonitorMetric(name: "app-memory", value: "0 B"),
                MonitorMetric(name: "cached", value: "0 B"),
                MonitorMetric(
                    name: "total",
                    value: memoryBytes(Double(ProcessInfo.processInfo.physicalMemory))
                )
            ]
            pressure = .normal
        case .battery:
            summary = "0%"
            metrics = [
                MonitorMetric(name: "type", value: "battery"),
                MonitorMetric(name: "status", value: "unknown"),
                MonitorMetric(name: "adapter", value: "not-connected"),
                MonitorMetric(name: "charging-power", value: "--"),
                MonitorMetric(name: "power", value: "--"),
                MonitorMetric(name: "adapter-input", value: "--"),
                MonitorMetric(name: "system-load", value: "--"),
                MonitorMetric(name: "battery-flow", value: "--"),
                MonitorMetric(name: "health", value: "--"),
                MonitorMetric(name: "cycle-count", value: "--"),
                MonitorMetric(name: "temperature", value: "--")
            ]
            pressure = nil
        case .codex:
            summary = "--"
            metrics = [
                MonitorMetric(name: "current", value: "--"),
                MonitorMetric(name: "average", value: "--"),
                MonitorMetric(name: "peak", value: "--")
            ]
            pressure = nil
        }

        return MonitorModule(
            kind: kind,
            context: nil,
            value: 0,
            summary: summary,
            metrics: metrics,
            samples: Array(repeating: 0, count: 28),
            pressure: pressure
        )
    }
}

nonisolated enum MonitorModuleMergePolicy {
    static func replacing(
        _ module: MonitorModule,
        in modules: [MonitorModule]
    ) -> [MonitorModule] {
        guard let index = modules.firstIndex(where: { $0.kind == module.kind }) else {
            return modules
        }
        var merged = modules
        merged[index] = module
        return merged
    }
}
