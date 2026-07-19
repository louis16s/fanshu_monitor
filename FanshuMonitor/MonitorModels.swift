import Foundation

nonisolated enum HaloRingSource: String, CaseIterable, Identifiable {
    case combined
    case cpu
    case gpu
    case memory
    case storage
    case network
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
        case .storage: String(localized: "kind.storage")
        case .network: String(localized: "kind.network")
        case .battery: String(localized: "kind.battery")
        case .codex: "Codex 5H"
        case .codexWeekly: "Codex Week"
        }
    }
}

nonisolated enum MemoryPressureLevel: Sendable {
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
    case storage
    case network
    case battery
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:
            "CPU"
        case .gpu:
            "GPU"
        case .memory:
            String(localized: "kind.memory")
        case .storage:
            String(localized: "kind.storage")
        case .network:
            String(localized: "kind.network")
        case .battery:
            String(localized: "kind.battery")
        case .codex:
            "Codex"
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
                MetricSwitch(id: "temperature", title: String(localized: "metric.gpu.temperature"), isDefault: false),
                MetricSwitch(id: "tiler", title: String(localized: "metric.gpu.tiler"), isDefault: false),
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
        case .codex:
            return [
                MetricSwitch(id: "plan", title: "套餐", isDefault: false),
                MetricSwitch(id: "five-hour", title: "5H", isDefault: true),
                MetricSwitch(id: "weekly", title: "一周", isDefault: true),
                MetricSwitch(id: "five-hour-reset", title: "5H刷新", isDefault: true),
                MetricSwitch(id: "weekly-reset", title: "周刷新", isDefault: false),
            ]
        }
    }
}

nonisolated struct MetricSwitch: Identifiable, Hashable {
    let id: String
    let title: String
    let isDefault: Bool
}

nonisolated struct MonitorMetric: Identifiable, Sendable {
    let name: String
    let value: String

    var id: String { name }
}

nonisolated struct MonitorModule: Identifiable, Sendable {
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
        case .codex:
            if value >= MonitorConstants.criticalThreshold { return .critical }
            if value >= MonitorConstants.warningThreshold { return .warning }
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
