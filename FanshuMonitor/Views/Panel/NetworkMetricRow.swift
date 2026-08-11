import SwiftUI

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
        let names: [MetricID] = ["ssid", "ipv4", "ipv6", "upload", "download"]
        return names.compactMap { name in
            guard enabledMetricNames.contains(name) else { return nil }
            return module.metrics.first(where: { $0.name == name })
        }
    }

    private var enabledMetricNames: Set<MetricID> {
        Set(details.map(\.name))
    }

    private func value(_ name: MetricID) -> String {
        module.metrics.first { $0.name == name }?.value ?? "--"
    }
}
