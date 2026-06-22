import ApplicationServices
import Combine
import SwiftUI

struct ModuleSettingsView: View {
    let kind: MonitorKind
    @ObservedObject var settings: MonitorSettings

    var body: some View {
        SettingsPage {
            SettingsGroup(String(localized: "settings.modules")) {
                SettingsRow(title: String(localized: "settings.show-in-panel")) {
                    Toggle("", isOn: Binding(
                        get: { settings.isVisible(kind) },
                        set: { settings.setVisible($0, for: kind) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            if kind == .codex {
                SettingsGroup("Codex") {
                    SettingsRow(title: String(localized: "settings.codex-refresh-interval"), subtitle: String(localized: "settings.codex-refresh-interval.subtitle")) {
                        Stepper(value: $settings.codexRefreshIntervalMinutes, in: 1...60, step: 1) {
                            Text(codexRefreshIntervalText)
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                }
            }

            SettingsGroup(String(localized: "settings.metrics")) {
                ForEach(Array(kind.availableMetrics.enumerated()), id: \.element.id) { index, metric in
                    let isSelected = settings.isMetricEnabled(metric.id, for: kind)
                    MetricSelectionRow(
                        title: metric.title,
                        isSelected: isSelected,
                        isEnabled: isLocked(metric) || settings.canEnableMetric(metric.id, for: kind),
                        isLocked: isLocked(metric)
                    ) {
                        guard !isLocked(metric) else { return }
                        settings.setMetric(metric.id, enabled: !isSelected, for: kind)
                    }

                    if index < kind.availableMetrics.count - 1 {
                        SettingsDivider()
                    }
                }

                if kind.availableMetrics.count > MonitorSettings.maximumEnabledMetricsPerKind {
                    SettingsDivider()

                    HStack {
                        Text(String(localized: "settings.metrics-limit") + "\(MonitorSettings.maximumEnabledMetricsPerKind)" + String(localized: "settings.metrics-limit-suffix"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    private func isLocked(_ metric: MetricSwitch) -> Bool {
        false
    }

    private var codexRefreshIntervalText: String {
        String(
            format: String(localized: "settings.minutes-format"),
            Int(settings.codexRefreshIntervalMinutes)
        )
    }
}

private struct MetricSelectionRow: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    var isLocked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isEnabled ? .primary : .secondary)

                Spacer(minLength: 16)

                if isSelected {
                    Text(isLocked ? "默认" : String(localized: "settings.visible"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

#if DISPLAY_CONTROL
struct DisplayModuleSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    var body: some View {
        SettingsPage {
            SettingsGroup("显示范围") {
                SettingsRow(title: "包含内建显示器", subtitle: "关闭后面板只显示外接屏") {
                    Toggle("", isOn: $settings.showBuiltInDisplays)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingsGroup("控制项") {
                SettingsRow(title: "亮度", subtitle: "支持内建屏系统亮度与外接屏 DDC 亮度") {
                    Toggle("", isOn: $settings.displayBrightnessControlEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "低亮度软件调光", subtitle: "DDC 到达最低亮度后，用屏幕遮罩继续变暗") {
                    Toggle("", isOn: $settings.displaySoftwareDimmingEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "音量", subtitle: "不需要显示器音量控制时可以关闭") {
                    Toggle("", isOn: $settings.displayVolumeControlEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "对比度", subtitle: "部分显示器支持 DDC 对比度") {
                    Toggle("", isOn: $settings.displayContrastControlEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingsGroup("亮度键") {
                SettingsRow(title: "接管 F1/F2", subtitle: "鼠标在可控外接屏上时拦截亮度键，否则交还系统") {
                    Toggle("", isOn: $settings.brightnessKeyInterceptionEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "系统亮度浮层", subtitle: "使用原生 OSD，并显示在正在调整的屏幕上") {
                    Toggle("", isOn: $settings.displayNativeOSDEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "亮度步进", subtitle: "F1/F2 每次调整的百分比") {
                    BrightnessStepControl(value: $settings.brightnessKeyStepPercent)
                }
            }

            SettingsGroup("面板显示") {
                SettingsRow(title: "显示可用性提示", subtitle: "显示“亮度可用/不可用原因”等诊断文字") {
                    Toggle("", isOn: $settings.displayAvailabilityHintsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }
}

private struct BrightnessStepControl: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Button {
                value = max(1, value - 1)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(value <= 1)

            Text("\(Int(value.rounded()))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 38)

            Button {
                value = min(20, value + 1)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(value >= 20)
        }
    }
}
#endif
