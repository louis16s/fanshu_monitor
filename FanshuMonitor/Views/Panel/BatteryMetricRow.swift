import SwiftUI

// MARK: - Battery Row

nonisolated enum BatteryBreathingAnimationPolicy {
    static func shouldAnimate(isPanelVisible: Bool, isActivelyCharging: Bool) -> Bool {
        isPanelVisible && isActivelyCharging
    }
}

struct BatteryGlassRow: View {
    let module: MonitorModule
    let theme: MonitorPanelTheme
    var details: [MonitorMetric] = []
    var isPanelVisible = false
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
                    .opacity(shouldAnimateBatteryBreath && batteryBreathIsDimmed ? 0.46 : 1)
                    .animation(
                        shouldAnimateBatteryBreath
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
                VStack(spacing: 7) {
                    if !powerFlowMetrics.isEmpty {
                        BatteryPowerFlowRow(
                            metrics: module.metrics,
                            isConnectedToPower: isConnectedToPower,
                            isActive: isPanelVisible && isExpanded,
                            theme: theme
                        )
                    }
                    if !regularDetailMetrics.isEmpty {
                        MetricDetailGrid(
                            metrics: regularDetailMetrics,
                            kind: module.kind,
                            theme: theme,
                            showsSeparator: powerFlowMetrics.isEmpty
                        )
                    }
                }
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
        .onChange(of: isPanelVisible) { _, _ in
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

    private var shouldAnimateBatteryBreath: Bool {
        BatteryBreathingAnimationPolicy.shouldAnimate(
            isPanelVisible: isPanelVisible,
            isActivelyCharging: isActivelyCharging
        )
    }

    private func updateBatteryBreath() {
        batteryBreathIsDimmed = shouldAnimateBatteryBreath
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
        let names: [MetricID] = isConnectedToPower
            ? ["adapter-input", "system-load", "battery-flow", "charging-power", "adapter", "health", "cycle-count", "temperature"]
            : ["system-load", "battery-flow", "adapter", "health", "cycle-count", "temperature"]

        let enabledNames = Set(details.map(\.name))

        return names.compactMap { name in
            guard enabledNames.contains(name) else { return nil }
            return module.metrics.first(where: { $0.name == name })
        }
    }

    private var canExpand: Bool {
        !detailMetrics.isEmpty
    }

    private var powerFlowMetrics: [MonitorMetric] {
        let names: [MetricID] = ["adapter-input", "system-load", "battery-flow"]
        return names.compactMap { name in
            detailMetrics.first(where: { $0.name == name })
        }
    }

    private var regularDetailMetrics: [MonitorMetric] {
        let powerFlowIDs: Set<MetricID> = ["adapter-input", "system-load", "battery-flow"]
        return detailMetrics.filter { !powerFlowIDs.contains($0.name) }
    }

    private func value(_ name: MetricID) -> String {
        let raw = rawValue(name)
        switch name {
        case "type", "status":
            return localizedBatteryState(raw)
        default:
            return raw
        }
    }

    private func rawValue(_ name: MetricID) -> String {
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
