import ApplicationServices
import Combine
import SwiftUI

struct ModuleSettingsView: View {
    let kind: MonitorKind
    @ObservedObject var settings: MonitorSettings

    var body: some View {
        SettingsPage {
            SettingsGroup {
                SettingsRow(title: String(localized: "settings.show-in-panel")) {
                    Toggle("", isOn: Binding(
                        get: { settings.isVisible(kind) },
                        set: { settings.setVisible($0, for: kind) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            SettingsGroup(String(localized: "settings.metrics")) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 0) {
                    ForEach(kind.availableMetrics) { metric in
                        let isSelected = settings.isMetricEnabled(metric.id, for: kind)
                        MetricSelectionRow(
                            title: metric.title,
                            isSelected: isSelected,
                            isEnabled: settings.canEnableMetric(metric.id, for: kind)
                        ) {
                            settings.setMetric(metric.id, enabled: !isSelected, for: kind)
                        }
                    }
                }
            }
            Text(String(localized: "settings.metrics-limit") + " \(MonitorSettings.maximumEnabledMetricsPerKind) " + String(localized: "settings.metrics-limit-suffix"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }
}

private struct MetricSelectionRow: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.body)
                    .foregroundStyle(isEnabled ? .primary : .secondary)

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

#if DISPLAY_CONTROL
struct DisplayModuleSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        SettingsPage {
            SettingsGroup("显示范围") {
                SettingsRow(title: "包含内建显示器", subtitle: "关闭后面板只显示外接屏。") {
                    Toggle("", isOn: $settings.showBuiltInDisplays)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingsGroup("控制项") {
                SettingsRow(title: "亮度", subtitle: "支持内建屏系统亮度与外接屏 DDC 亮度。") {
                    Toggle("", isOn: $settings.displayBrightnessControlEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "低亮度软件调光", subtitle: "DDC 到达最低亮度后，用屏幕遮罩继续变暗。") {
                    Toggle("", isOn: $settings.displaySoftwareDimmingEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "音量", subtitle: "不需要显示器音量控制时可以关闭。") {
                    Toggle("", isOn: $settings.displayVolumeControlEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "对比度", subtitle: "部分显示器支持 DDC 对比度。") {
                    Toggle("", isOn: $settings.displayContrastControlEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingsGroup("亮度键") {
                SettingsRow(title: "辅助功能权限", subtitle: "允许应用拦截 F1/F2，并按鼠标所在屏幕分配亮度控制。") {
                    Button(accessibilityTrusted ? "已授权" : "授权") {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                        accessibilityTrusted = AXIsProcessTrusted()
                    }
                    .fixedSize()
                    .disabled(accessibilityTrusted)
                }

                SettingsDivider()

                SettingsRow(title: "接管 F1/F2", subtitle: "鼠标在可控外接屏上时拦截亮度键，否则交还系统。") {
                    Toggle("", isOn: $settings.brightnessKeyInterceptionEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "系统亮度浮层", subtitle: "使用原生 OSD，并显示在正在调整的屏幕上。") {
                    Toggle("", isOn: $settings.displayNativeOSDEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "亮度步进", subtitle: "F1/F2 每次调整的百分比。") {
                    BrightnessStepControl(value: $settings.brightnessKeyStepPercent)
                }
            }

            SettingsGroup("面板显示") {
                SettingsRow(title: "显示可用性提示", subtitle: "显示“亮度可用/不可用原因”等诊断文字。") {
                    Toggle("", isOn: $settings.displayAvailabilityHintsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
        .onAppear {
            accessibilityTrusted = AXIsProcessTrusted()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
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
