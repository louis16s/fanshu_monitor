import AppKit
import SwiftUI

struct MonitorPanelView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var settings: MonitorSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @Namespace private var glassNamespace
    @ObservedObject private var panelExpansionState: PanelExpansionState

    init(store: MonitorStore, settings: MonitorSettings) {
        self.store = store
        self.settings = settings
        panelExpansionState = store.panelExpansionState
    }

    var body: some View {
        let theme = MonitorPanelTheme(
            palette: MonitorPalette(
                preference: settings.colorSchemePreference,
                colorScheme: colorScheme
            )
        )

        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 5) {
                // Header: Live 脉冲点 + 时间
                header(theme: theme)

                ForEach(store.modules) { module in
                    row(for: module, theme: theme)
                        .glassEffectID("metric-\(module.kind.id)", in: glassNamespace)
                }

                if settings.displayModuleVisible {
                    DisplayControlsSection(
                        settings: settings,
                        controller: store.displayController,
                        isExpanded: panelExpansionState.isExpanded(.display)
                    ) {
                        panelExpansionState.toggle(.display)
                    }
                        .glassEffectID("display-controls", in: glassNamespace)
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(width: MonitorConstants.panelWidth)
            .background(panelBackgroundColor)
        }
        .containerBackground(.clear, for: .window)
        .background(TransparentWindowBackground(colorSchemeOverride: settings.themePreference.colorScheme))
        .background {
            PanelWindowVisibilityTracker { isVisible in
                store.setPanelVisible(isVisible)
            }
        }
    }

    private var panelBackgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.35)
            : Color.white.opacity(0.45)
    }

    private func header(theme: MonitorPanelTheme) -> some View {
        HStack {
            HStack(spacing: 5) {
                Circle()
                    .fill(theme.liveDot(for: store.haloRingLoadLevel))
                    .frame(width: 5, height: 5)

                Text("番薯monitor · v\(appVersion)")
                    .panelLabelFont(size: 9, tracking: 1.1)
                    .foregroundStyle(theme.captionText)

            }

            Spacer()

            Button {
                store.lockScreenController.lockNow()
            } label: {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.captionText)
            .help("立即锁屏")
            .accessibilityLabel("立即锁屏")

            Button {
                SettingsWindowPresenter.open(openSettings)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.captionText)
            .help("设置")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.captionText)
            .help("退出")

            Text(timeString)
                .panelMonoFont(size: 9, weight: .medium)
                .foregroundStyle(theme.captionText)
        }
        .padding(.horizontal, 4)
        .frame(height: 20)
    }

    @ViewBuilder
    private func row(for module: MonitorModule, theme: MonitorPanelTheme) -> some View {
        switch module.kind {
        case .cpu:
            MetricGlassRow(
                module: module,
                theme: theme,
                detail: module.summary,
                samples: module.samples,
                details: enabledMetrics(for: module),
                isExpanded: panelExpansionState.isExpanded(.module(module.kind))
            ) {
                toggleExpansion(for: module.kind)
            }
        case .gpu:
            MetricGlassRow(
                module: module,
                theme: theme,
                detail: module.summary,
                samples: module.samples,
                details: enabledMetrics(for: module),
                isExpanded: panelExpansionState.isExpanded(.module(module.kind))
            ) {
                toggleExpansion(for: module.kind)
            }
        case .memory:
            MetricGlassRow(
                module: module,
                theme: theme,
                detail: module.summary,
                details: enabledMetrics(for: module),
                isExpanded: panelExpansionState.isExpanded(.module(module.kind))
            ) {
                toggleExpansion(for: module.kind)
            }
        case .network:
            NetworkGlassRow(
                module: module,
                theme: theme,
                details: enabledMetrics(for: module),
                isExpanded: panelExpansionState.isExpanded(.module(module.kind))
            ) {
                toggleExpansion(for: module.kind)
            }
        case .battery:
            BatteryGlassRow(
                module: module,
                theme: theme,
                details: enabledMetrics(for: module),
                isPanelVisible: store.isPanelVisible,
                isExpanded: panelExpansionState.isExpanded(.module(module.kind))
            ) {
                toggleExpansion(for: module.kind)
            }
        case .codex:
            MetricGlassRow(
                module: module,
                theme: theme,
                detail: codexHeaderDetail(for: module),
                details: enabledMetrics(for: module),
                codexTasks: settings.isMetricEnabled(.activeTasks, for: .codex)
                    ? store.codexTasks
                    : [],
                isExpanded: panelExpansionState.isExpanded(.module(module.kind))
            ) {
                toggleExpansion(for: module.kind)
            }
        }
    }

    private func enabledMetrics(for module: MonitorModule) -> [MonitorMetric] {
        let enabledIds = settings.enabledMetrics[module.kind] ?? defaultMetricIds(for: module.kind)
        let resolvedIds = module.kind.resolvedPanelMetricIDs(from: enabledIds)
        return module.metrics.filter { resolvedIds.contains($0.name) }
    }

    private func codexHeaderDetail(for module: MonitorModule) -> String {
        switch settings.codexHeaderDetailPreference {
        case .plan:
            return module.metrics.first { $0.name == .plan }?.value ?? module.summary
        case .remaining:
            let presentation = CodexQuotaPresentation(metrics: module.metrics)
            if presentation.hasFiveHourQuota {
                return "5H \(presentation.fiveHourText)"
            }
            guard presentation.hasWeeklyQuota else { return "--" }
            return "\(String(localized: "metric.codex.weekly")) \(presentation.weeklyText)"
        }
    }

    private func defaultMetricIds(for kind: MonitorKind) -> Set<MetricID> {
        Set(kind.availableMetrics.filter { $0.isDefault }.map { $0.id })
    }

    private func toggleExpansion(for kind: MonitorKind) {
        withAnimation(.smooth(duration: 0.18)) {
            panelExpansionState.toggle(.module(kind))
        }
    }

    private var timeString: String {
        Self.panelTimeFormatter.string(from: Date())
    }

    private var appVersion: String {
        AppVersion.current
    }

    private static let panelTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
