import SwiftUI

struct MetricGlassRow: View {
    let module: MonitorModule
    let theme: MonitorPanelTheme
    let detail: String
    var samples: [Double] = []
    var details: [MonitorMetric] = []
    var codexTasks: [CodexTaskProgress] = []
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
                    if module.kind == .codex {
                        CodexMetricDetailGrid(
                            metrics: details,
                            tasks: codexTasks,
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

    private var hasExpandedDetails: Bool {
        !details.isEmpty || (module.kind == .codex && !codexTasks.isEmpty)
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
        case .memory:
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

}

// MARK: - Detail Grid

struct MetricDetailGrid: View {
    let metrics: [MonitorMetric]
    let kind: MonitorKind
    let theme: MonitorPanelTheme
    var showsSeparator = true

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(spacing: 7) {
            if showsSeparator {
                Rectangle()
                    .fill(theme.rowSeparator(for: kind))
                    .frame(height: 1)
                    .padding(.leading, 28)
            }

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
                    PanelPasteboard.copy(metric.value)
                }
        }
    }
}

private struct CodexMetricDetailGrid: View {
    let metrics: [MonitorMetric]
    let tasks: [CodexTaskProgress]
    let presentation: CodexQuotaPresentation
    let theme: MonitorPanelTheme

    private var quotaMetrics: [MonitorMetric] {
        var result = metrics
        if !presentation.hasFiveHourQuota {
            result.removeAll { $0.name == .fiveHour || $0.name == .fiveHourReset }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(tasks) { task in
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
                .help(task.activeStep ?? String(localized: "codex.task.running"))
            }

            MetricDetailGrid(metrics: quotaMetrics, kind: .codex, theme: theme)
        }
    }
}

private func localizedMetricName(kind: MonitorKind, id: MetricID) -> String {
    let key = "metric.\(kind.rawValue).\(id.rawValue)"
    let localized = String(localized: String.LocalizationValue(key))
    return localized == key ? id.rawValue : localized
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

func localizedBatteryState(_ id: String) -> String {
    let key = "battery-state.\(id)"
    let localized = String(localized: String.LocalizationValue(key))
    return localized == key ? id : localized
}
