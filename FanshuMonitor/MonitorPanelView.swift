import AppKit
import SwiftUI

struct MonitorPanelView: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @Namespace private var glassNamespace
    @State private var expandedKinds: Set<MonitorKind> = Set(MonitorKind.allCases)

    var body: some View {
        let theme = MonitorPanelTheme(
            palette: MonitorPalette(
                preference: store.settings.colorSchemePreference,
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

                #if DISPLAY_CONTROL
                if store.settings.displayModuleVisible {
                    DisplayControlsSection(settings: store.settings, controller: store.displayController)
                        .glassEffectID("display-controls", in: glassNamespace)
                }
                #endif
            }
            .padding(.top, 6)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(width: MonitorConstants.panelWidth)
            .background(panelBackgroundColor)
        }
        .containerBackground(.clear, for: .window)
        .background(TransparentWindowBackground(colorSchemeOverride: store.settings.themePreference.colorScheme))
        .onAppear {
            store.panelDidAppear()
        }
        .onDisappear {
            store.panelDidDisappear()
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

                LockScreenExecutionIndicator(
                    controller: store.lockScreenController,
                    color: theme.captionText
                )
            }

            Spacer()

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
                isExpanded: expandedKinds.contains(module.kind)
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
                isExpanded: expandedKinds.contains(module.kind)
            ) {
                toggleExpansion(for: module.kind)
            }
        case .memory:
            MetricGlassRow(
                module: module,
                theme: theme,
                detail: module.summary,
                details: enabledMetrics(for: module),
                isExpanded: expandedKinds.contains(module.kind)
            ) {
                toggleExpansion(for: module.kind)
            }
        case .storage:
            MetricGlassRow(
                module: module,
                theme: theme,
                detail: module.summary,
                details: enabledMetrics(for: module),
                isExpanded: expandedKinds.contains(module.kind)
            ) {
                toggleExpansion(for: module.kind)
            }
        case .network:
            NetworkGlassRow(
                module: module,
                theme: theme,
                details: enabledMetrics(for: module),
                isExpanded: expandedKinds.contains(module.kind)
            ) {
                toggleExpansion(for: module.kind)
            }
        case .battery:
            BatteryGlassRow(
                module: module,
                theme: theme,
                details: enabledMetrics(for: module),
                isExpanded: expandedKinds.contains(module.kind)
            ) {
                toggleExpansion(for: module.kind)
            }
        case .codex:
            MetricGlassRow(
                module: module,
                theme: theme,
                detail: module.summary,
                details: enabledMetrics(for: module),
                showsCodexTasks: store.settings.isMetricEnabled("active-tasks", for: .codex),
                isExpanded: expandedKinds.contains(module.kind)
            ) {
                toggleExpansion(for: module.kind)
            }
        }
    }

    private func enabledMetrics(for module: MonitorModule) -> [MonitorMetric] {
        let enabledIds = store.settings.enabledMetrics[module.kind] ?? defaultMetricIds(for: module.kind)
        return module.metrics.filter { enabledIds.contains($0.name) }
    }

    private func defaultMetricIds(for kind: MonitorKind) -> Set<String> {
        Set(kind.availableMetrics.filter { $0.isDefault }.map { $0.id })
    }

    private func toggleExpansion(for kind: MonitorKind) {
        withAnimation(.smooth(duration: 0.18)) {
            if expandedKinds.contains(kind) {
                expandedKinds.remove(kind)
            } else {
                expandedKinds.insert(kind)
            }
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

private struct LockScreenExecutionIndicator: View {
    @ObservedObject var controller: LockScreenPolicyController
    let color: Color

    var body: some View {
        if showsIndicator, let activePolicy = controller.activePolicy {
            Image(systemName: symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(indicatorColor)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .help(helpText(for: activePolicy))
                .accessibilityLabel("锁屏策略执行中")
                .accessibilityValue(activePolicy.timeRangeText)
        }
    }

    private var showsIndicator: Bool {
        switch controller.status {
        case .active, .locking, .locked, .lockFailed, .environmentFailed:
            true
        case .disabled, .restored, .systemSettingsChanged, .systemSettingsBlocked,
             .noRules, .waiting, .waitingForPower, .waitingForPowerSource, .sessionInactive:
            false
        }
    }

    private var symbolName: String {
        switch controller.status {
        case .lockFailed, .environmentFailed:
            "exclamationmark.triangle.fill"
        case .locking, .locked:
            "lock.fill"
        default:
            "lock.badge.clock"
        }
    }

    private var indicatorColor: Color {
        switch controller.status {
        case .lockFailed, .environmentFailed:
            .orange
        default:
            color
        }
    }

    private func helpText(for policy: LockScreenPolicy) -> String {
        switch controller.status {
        case .lockFailed, .environmentFailed:
            controller.statusText
        default:
            "锁屏策略执行中 · \(policy.timeRangeText) · 闲置 \(policy.idleMinutes) 分钟"
        }
    }
}
