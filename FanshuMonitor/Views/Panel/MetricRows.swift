import AppKit
import SwiftUI

struct MetricGlassRow: View {
    let module: MonitorModule
    let theme: MonitorPanelTheme
    let detail: String
    var samples: [Double] = []
    var details: [MonitorMetric] = []
    var showsCodexTasks = false
    var isExpanded = false
    var toggleExpansion: (() -> Void)?

    private var tint: Color {
        theme.moduleTint(for: module.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelModuleHeader(
                title: titleText,
                value: detail,
                titleColor: theme.primaryText,
                valueColor: theme.valueText
            ) {
                PanelModuleIcon(systemName: module.kind.symbol, color: tint)
            } trailing: {
                trailingView(theme: theme)
            }

            if isExpanded, hasExpandedDetails {
                Group {
                    if let storageVolumes {
                        StorageVolumeDetailList(volumes: storageVolumes, kind: module.kind, tint: tint, theme: theme)
                    } else if module.kind == .codex {
                        CodexMetricDetailGrid(
                            metrics: details + codexTaskMetrics,
                            presentation: CodexQuotaPresentation(metrics: module.metrics),
                            theme: theme
                        )
                    } else {
                        MetricDetailGrid(metrics: details, kind: module.kind, theme: theme)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
                .transition(.panelDetailDisclosure)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleExpansion?()
        }
        .glassEffect(.regular.tint(theme.rowGlassTint(for: module.kind)), in: .rect(cornerRadius: MonitorConstants.rowCornerRadius, style: .continuous))
    }

    private var codexTaskMetrics: [MonitorMetric] {
        guard showsCodexTasks else { return [] }
        return module.metrics.filter { $0.name.hasPrefix("active-task-") }
    }

    private var hasExpandedDetails: Bool {
        !details.isEmpty || (module.kind == .codex && showsCodexTasks)
    }

    private var titleText: String {
        "\(module.kind.panelTitle):"
    }

    @ViewBuilder
    private func trailingView(theme: MonitorPanelTheme) -> some View {
        switch module.kind {
        case .cpu, .gpu:
            if !samples.isEmpty {
                SparklineChart(samples: samples, tint: tint)
                    .frame(width: 56, height: 18)
            }
        case .memory, .storage:
            ProgressMeter(value: module.value, tint: tint, theme: theme)
                .frame(width: 56, height: 3)
        case .network, .battery:
            EmptyView()
        case .codex:
            ProgressMeter(
                value: CodexQuotaPresentation(metrics: module.metrics).progressValue,
                tint: tint,
                theme: theme
            )
                .frame(width: 72, height: 3)
        }
    }

    private var storageVolumes: [StorageVolumeInfo]? {
        guard module.kind == .storage else {
            return nil
        }

        let externalVolumes = parseExternalVolumes(module.context)
        guard !externalVolumes.isEmpty else {
            return nil
        }

        return [systemVolumeInfo] + externalVolumes
    }

    private var systemVolumeInfo: StorageVolumeInfo {
        StorageVolumeInfo(
            id: "system",
            name: String(localized: "panel.system-volume"),
            used: metricValue("used"),
            free: metricValue("free"),
            total: metricValue("total"),
            percentage: Int(module.value.rounded()),
            isExternal: false
        )
    }

    private func metricValue(_ name: String) -> String {
        details.first { $0.name == name }?.value ?? "--"
    }
}

// MARK: - Detail Grid

private struct MetricDetailGrid: View {
    let metrics: [MonitorMetric]
    let kind: MonitorKind
    let theme: MonitorPanelTheme

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 7) {
            Rectangle()
                .fill(theme.rowSeparator(for: kind))
                .frame(height: 1)
                .padding(.leading, 28)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(metrics) { metric in
                    metricCell(metric, theme: theme)
                }
            }
            .padding(.leading, 28)
        }
    }

    private func metricCell(_ metric: MonitorMetric, theme: MonitorPanelTheme) -> some View {
        HStack(spacing: 6) {
            Text(localizedMetricName(kind: kind, id: metric.name))
                .panelCaptionFont(size: 10)
                .foregroundStyle(theme.captionText)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(localizedMetricValue(kind: kind, metric: metric))
                .panelMonoFont(size: 11, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .contentShape(Rectangle())
                .onTapGesture {
                    copyToPasteboard(metric.value)
                }
        }
    }
}

private struct CodexMetricDetailGrid: View {
    let metrics: [MonitorMetric]
    let presentation: CodexQuotaPresentation
    let theme: MonitorPanelTheme

    private struct ActiveTask: Identifiable {
        let id: Int
        let title: String
        let progressText: String
        let status: String

        var percent: Double? {
            guard let percentPart = progressText.split(separator: "·").last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "%", with: ""),
                  let percent = Double(percentPart)
            else {
                return nil
            }
            return min(100, max(0, percent))
        }

        var countText: String {
            progressText.split(separator: "·").first.map(String.init) ?? progressText
        }
    }

    private var activeTasks: [ActiveTask] {
        metrics.compactMap { metric -> Int? in
            guard metric.name.hasPrefix("active-task-title-") else { return nil }
            return Int(metric.name.replacingOccurrences(of: "active-task-title-", with: ""))
        }
        .sorted()
        .compactMap { index in
            guard let title = metrics.first(where: { $0.name == "active-task-title-\(index)" })?.value,
                  let progress = metrics.first(where: { $0.name == "active-task-progress-\(index)" })?.value
            else {
                return nil
            }
            let status = metrics.first(where: { $0.name == "active-task-status-\(index)" })?.value ?? "执行中"
            return ActiveTask(id: index, title: title, progressText: progress, status: status)
        }
    }

    private var quotaMetrics: [MonitorMetric] {
        var result = metrics.filter { !$0.name.hasPrefix("active-task-") }
        if !presentation.hasFiveHourQuota {
            result.removeAll { $0.name == "five-hour" || $0.name == "five-hour-reset" }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(activeTasks) { task in
                HStack(spacing: 6) {
                    Image(systemName: "circle.dashed.inset.filled")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.moduleTint(for: .codex))

                    Text(task.title)
                        .panelCaptionFont(size: 10)
                        .foregroundStyle(theme.captionText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 6)

                    if let percent = task.percent {
                        ProgressMeter(
                            value: percent,
                            tint: theme.moduleTint(for: .codex),
                            theme: theme
                        )
                        .frame(width: 42, height: 3)
                    }

                    Text(task.countText)
                        .panelMonoFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.leading, 28)
                .help(task.status)
            }

            MetricDetailGrid(metrics: quotaMetrics, kind: .codex, theme: theme)
        }
    }
}

private func localizedMetricName(kind: MonitorKind, id: String) -> String {
    if let name = chineseMetricName(kind: kind, id: id) {
        return name
    }
    let key = "metric.\(kind.rawValue).\(id)"
    let localized = String(localized: String.LocalizationValue(key))
    return localized == key ? id : localized
}

private func chineseMetricName(kind: MonitorKind, id: String) -> String? {
    switch (kind, id) {
    case (.memory, "app-memory"): return "应用占用"
    case (.memory, "cached"): return "缓存"
    case (.memory, "compressed"): return "已压缩"
    case (.network, "ssid"): return "无线名称"
    case (.network, "ipv4"): return "IPv4 地址"
    case (.network, "ipv6"): return "IPv6 地址"
    case (.network, "upload"): return "上传"
    case (.network, "download"): return "下载"
    case (.battery, "charging-power"): return "充电功率"
    case (.battery, "adapter"): return "适配器"
    case (.gpu, "temperature"): return "温度"
    case (.codex, "plan"): return "套餐"
    case (.codex, "five-hour"): return "5H"
    case (.codex, "weekly"): return "一周"
    case (.codex, "five-hour-reset"): return "5H刷新"
    case (.codex, "weekly-reset"): return "周刷新"
    case (.codex, "reset-credits"): return "重置卡"
    case (.codex, "next-reset"): return "下次刷新"
    case (.codex, "status"): return "状态"
    default: return nil
    }
}

private func localizedMetricValue(kind: MonitorKind, metric: MonitorMetric) -> String {
    switch (kind, metric.name) {
    case (.memory, "pressure"):
        return localizedMemoryPressure(metric.value)
    case (.battery, "adapter"):
        return localizedBatteryState(metric.value)
    default:
        return metric.value
    }
}

private func localizedMemoryPressure(_ id: String) -> String {
    let key = "memory-pressure.\(id)"
    let localized = String(localized: String.LocalizationValue(key))
    return localized == key ? id : localized
}

private struct StorageVolumeDetailList: View {
    let volumes: [StorageVolumeInfo]
    let kind: MonitorKind
    let tint: Color
    let theme: MonitorPanelTheme

    var body: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(theme.rowSeparator(for: kind))
                .frame(height: 1)
                .padding(.leading, 28)

            VStack(spacing: 8) {
                ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                    if index > 0 {
                        Rectangle()
                            .fill(theme.rowSeparator(for: kind).opacity(0.72))
                            .frame(height: 1)
                            .padding(.leading, 22)
                    }

                    StorageVolumeRow(volume: volume, kind: kind, tint: tint, theme: theme)
                }
            }
            .padding(.leading, 28)
        }
    }
}

private struct StorageVolumeRow: View {
    let volume: StorageVolumeInfo
    let kind: MonitorKind
    let tint: Color
    let theme: MonitorPanelTheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: volume.symbol)
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(volume.name)
                        .panelCaptionFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(volume.name)

                    Spacer(minLength: 8)

                    Text("\(volume.clampedPercentage)%")
                        .panelMonoFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(theme.badgeFill(for: kind))
                        }
                }

                ProgressMeter(value: Double(volume.clampedPercentage), tint: tint, theme: theme)
                    .frame(height: 3)

                HStack(spacing: 8) {
                    StorageVolumeStat(label: String(localized: "metric.storage.used"), value: volume.used, theme: theme)
                    StorageVolumeStat(label: String(localized: "metric.storage.free"), value: volume.free, theme: theme)
                    StorageVolumeStat(label: String(localized: "metric.storage.total"), value: volume.total, theme: theme)
                }
            }
        }
    }
}

private struct StorageVolumeStat: View {
    let label: String
    let value: String
    let theme: MonitorPanelTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .panelCaptionFont(size: 9)
                .foregroundStyle(theme.captionText)
                .lineLimit(1)

            Text(value)
                .panelMonoFont(size: 10, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StorageVolumeInfo: Identifiable {
    let id: String
    let name: String
    let used: String
    let free: String
    let total: String
    let percentage: Int

    var isExternal: Bool

    var symbol: String {
        isExternal ? "externaldrive" : "internaldrive"
    }

    var clampedPercentage: Int {
        min(100, max(0, percentage))
    }
}

// MARK: - Network Row

struct NetworkGlassRow: View {
    let module: MonitorModule
    let theme: MonitorPanelTheme
    var details: [MonitorMetric] = []
    var isExpanded = false
    var toggleExpansion: (() -> Void)?

    private var tint: Color {
        theme.moduleTint(for: module.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelModuleHeader(
                title: "\(module.kind.panelTitle):",
                value: module.summary,
                titleColor: theme.primaryText,
                valueColor: theme.valueText
            ) {
                PanelModuleIcon(systemName: "wifi", color: tint)
            } trailing: {
                HStack(spacing: 6) {
                    if enabledMetricNames.contains("upload") {
                        NetworkRatePill(systemImage: "arrow.up", text: value("upload"), theme: theme)
                    }
                    if enabledMetricNames.contains("download") {
                        NetworkRatePill(systemImage: "arrow.down", text: value("download"), theme: theme)
                    }
                }
            }

            if isExpanded {
                MetricDetailGrid(metrics: detailMetrics, kind: module.kind, theme: theme)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
                    .transition(.panelDetailDisclosure)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleExpansion?()
        }
        .glassEffect(.regular.tint(theme.rowGlassTint(for: module.kind)), in: .rect(cornerRadius: MonitorConstants.rowCornerRadius, style: .continuous))
    }

    private var detailMetrics: [MonitorMetric] {
        let names = ["ssid", "ipv4", "ipv6", "upload", "download"]
        return names.compactMap { name in
            guard enabledMetricNames.contains(name) else { return nil }
            return module.metrics.first(where: { $0.name == name })
        }
    }

    private var enabledMetricNames: Set<String> {
        Set(details.map(\.name))
    }

    private func value(_ name: String) -> String {
        module.metrics.first { $0.name == name }?.value ?? "--"
    }
}

// MARK: - Battery Row

struct BatteryGlassRow: View {
    let module: MonitorModule
    let theme: MonitorPanelTheme
    var details: [MonitorMetric] = []
    var isExpanded = false
    var toggleExpansion: (() -> Void)?
    @State private var batteryBreathIsDimmed = false

    private var tint: Color {
        theme.moduleTint(for: module.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelModuleHeader(
                title: "\(module.kind.panelTitle):",
                value: summaryText,
                titleColor: theme.primaryText,
                valueColor: theme.valueText
            ) {
                PanelModuleIcon(systemName: powerSymbol, color: tint)
                    .opacity(isActivelyCharging && batteryBreathIsDimmed ? 0.46 : 1)
                    .animation(
                        isActivelyCharging
                            ? .easeInOut(duration: MonitorConstants.batteryAnimationDuration).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.18),
                        value: batteryBreathIsDimmed
                    )
            } trailing: {
                if hasBattery {
                    MetricPill(systemImage: powerPillIcon, text: powerPillValue, theme: theme)
                } else {
                    HStack(spacing: 6) {
                        MetricPill(systemImage: "powerplug", text: value("adapter"), theme: theme)
                        MetricPill(systemImage: "gauge.with.dots.needle.33percent", text: value("power"), theme: theme)
                    }
                }
            }

            if canExpand && isExpanded {
                MetricDetailGrid(metrics: detailMetrics, kind: module.kind, theme: theme)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
                    .transition(.panelDetailDisclosure)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canExpand {
                toggleExpansion?()
            }
        }
        .onAppear {
            updateBatteryBreath()
        }
        .onChange(of: isActivelyCharging) { _, _ in
            updateBatteryBreath()
        }
        .glassEffect(.regular.tint(theme.rowGlassTint(for: module.kind)), in: .rect(cornerRadius: MonitorConstants.rowCornerRadius, style: .continuous))
    }

    private var hasBattery: Bool {
        rawValue("type") == "battery"
    }

    private var isCharging: Bool {
        rawValue("status") == "charging"
    }

    private var isActivelyCharging: Bool {
        hasBattery
            && isCharging
            && module.value < 99.5
            && positiveWattValue(rawValue("charging-power")) != nil
    }

    private func updateBatteryBreath() {
        batteryBreathIsDimmed = isActivelyCharging
    }

    private var powerSymbol: String {
        guard hasBattery else {
            return "powerplug"
        }
        if isCharging {
            return "battery.100percent.bolt"
        }
        switch module.value {
        case 76...100:
            return "battery.100percent"
        case 51..<76:
            return "battery.75percent"
        case 26..<51:
            return "battery.50percent"
        case 11..<26:
            return "battery.25percent"
        default:
            return "battery.0percent"
        }
    }

    private var powerPillIcon: String {
        return "gauge.with.dots.needle.33percent"
    }

    private var powerPillValue: String {
        return value("power")
    }

    private var summaryText: String {
        localizedBatteryState(module.summary)
    }

    private var detailMetrics: [MonitorMetric] {
        let names = isConnectedToPower
            ? ["charging-power", "adapter", "health", "cycle-count", "temperature"]
            : ["adapter", "health", "cycle-count", "temperature"]

        let enabledNames = Set(details.map(\.name))

        return names.compactMap { name in
            guard enabledNames.contains(name) else { return nil }
            return module.metrics.first(where: { $0.name == name })
        }
    }

    private var canExpand: Bool {
        !detailMetrics.isEmpty
    }

    private func value(_ name: String) -> String {
        let raw = rawValue(name)
        switch name {
        case "type", "status":
            return localizedBatteryState(raw)
        default:
            return raw
        }
    }

    private func rawValue(_ name: String) -> String {
        module.metrics.first { $0.name == name }?.value ?? "--"
    }

    private var isConnectedToPower: Bool {
        rawValue("status") != "on-battery"
    }

    private func positiveWattValue(_ value: String) -> Double? {
        let normalized = value
            .replacingOccurrences(of: "W", with: "")
            .replacingOccurrences(of: "瓦", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(normalized), number > 0.05 else {
            return nil
        }
        return number
    }
}

private func localizedBatteryState(_ id: String) -> String {
    let key = "battery-state.\(id)"
    let localized = String(localized: String.LocalizationValue(key))
    return localized == key ? id : localized
}

private func parseExternalVolumes(_ context: String?) -> [StorageVolumeInfo] {
    guard let context, let data = context.data(using: .utf8) else {
        return []
    }

    guard let payload = try? JSONDecoder().decode([ExternalVolumePayload].self, from: data) else {
        return []
    }

    return payload.enumerated().map { index, volume in
        StorageVolumeInfo(
            id: "external-\(index)-\(volume.name)",
            name: volume.name,
            used: volume.used,
            free: volume.free,
            total: volume.total,
            percentage: volume.percentage,
            isExternal: true
        )
    }
}

private struct ExternalVolumePayload: Decodable {
    let name: String
    let used: String
    let free: String
    let total: String
    let percentage: Int
}
private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
