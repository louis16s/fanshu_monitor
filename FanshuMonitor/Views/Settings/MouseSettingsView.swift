import Combine
import SwiftUI

struct MouseSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @ObservedObject var controller: MouseControlController

    var body: some View {
        SettingsPage {
            SettingsGroup("鼠标增强") {
                SettingsRow(title: "启用鼠标增强", subtitle: "接管可编程按键，关闭时不启动鼠标监听") {
                    Toggle("", isOn: $settings.mouseControlEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingsGroup("设备") {
                SettingsRow(title: "当前鼠标", subtitle: controller.combinedStatusLine) {
                    Button {
                        controller.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.mouseControlEnabled)
                    .help("重新检测鼠标")
                }

                SettingsDivider()

                SettingsRow(title: "DPI 省电模式", subtitle: "仅在打开鼠标设置或点击应用时读取 DPI，平时不访问 HID++") {
                    Toggle("", isOn: $settings.mouseDPIOnDemandEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "DPI", subtitle: "MX Anywhere 3S 支持最高 8000") {
                    MouseDPIControl(
                        dpi: $settings.mouseDPI,
                        isEnabled: settings.mouseControlEnabled,
                        isApplying: controller.isApplyingDPI
                    ) {
                        controller.applyDPI(Int(settings.mouseDPI.rounded()))
                    }
                }
            }

            SettingsGroup("按钮映射") {
                ForEach(Array(MouseButtonSlot.settingsOrder.enumerated()), id: \.element.id) { index, slot in
                    MouseActionRow(settings: settings, slot: slot)
                    if index < MouseButtonSlot.settingsOrder.count - 1 {
                        SettingsDivider()
                    }
                }
            }
        }
        .onAppear {
            if settings.mouseDPIOnDemandEnabled {
                controller.refreshIfNeeded()
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            controller.refreshButtonTapIfPossible()
        }
    }
}

private struct MouseDPIControl: View {
    @Binding var dpi: Double
    let isEnabled: Bool
    let isApplying: Bool
    let apply: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $dpi, in: 200...8000, step: 50)
                .frame(width: 190)
                .disabled(!isEnabled || isApplying)

            Text("\(Int(dpi.rounded()))")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)

            Button(isApplying ? "应用中" : "应用") {
                apply()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .disabled(!isEnabled || isApplying)
        }
    }
}

private struct MouseActionRow: View {
    @ObservedObject var settings: MonitorSettings
    let slot: MouseButtonSlot

    var body: some View {
        SettingsRow(title: slot.title, subtitle: nil) {
            Picker(slot.title, selection: binding) {
                ForEach(MouseButtonAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var binding: Binding<MouseButtonAction> {
        Binding(
            get: { settings.mouseAction(for: slot) },
            set: { settings.setMouseAction($0, for: slot) }
        )
    }
}
