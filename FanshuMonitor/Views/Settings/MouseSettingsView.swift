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
                    ) { dpi in
                        controller.applyDPI(dpi)
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
    let apply: (Int) -> Void

    private let range: ClosedRange<Double> = 200...8000
    private let presets = [800, 1600, 2400, 4000, 8000]

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(spacing: 10) {
                MouseDPITrackSlider(
                    value: $dpi,
                    range: range,
                    step: 50,
                    isEnabled: isEnabled && !isApplying
                )
                .frame(width: 190, height: 18)

                Text("\(Int(dpi.rounded()))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)

                Button(isApplying ? "应用中" : "应用") {
                    apply(Int(dpi.rounded()))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .disabled(!isEnabled || isApplying)
            }

            HStack(spacing: 5) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        dpi = Double(preset)
                    } label: {
                        Text(presetText(preset))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(minWidth: 36)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!isEnabled || isApplying)
                }
            }
        }
    }

    private func presetText(_ value: Int) -> String {
        value >= 1000 ? "\(value / 1000)k" : "\(value)"
    }
}

private struct MouseDPITrackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let isEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            let trackHeight: CGFloat = 5
            let thumbSize: CGFloat = 16
            let width = max(thumbSize, proxy.size.width)
            let clamped = min(range.upperBound, max(range.lowerBound, value))
            let progress = (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
            let fillWidth = width * progress
            let thumbX = width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(isEnabled ? 0.18 : 0.12))
                    .frame(height: trackHeight)
                    .overlay {
                        Capsule()
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 0.7)
                    }

                Capsule()
                    .fill(isEnabled ? Color.accentColor : Color.secondary.opacity(0.72))
                    .frame(width: fillWidth, height: trackHeight)

                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.20), radius: 2.5, x: 0, y: 1)
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.46), lineWidth: 0.6)
                    }
                    .offset(x: min(max(0, thumbX - thumbSize / 2), width - thumbSize))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        let progress = min(1, max(0, gesture.location.x / width))
                        let rawValue = range.lowerBound + progress * (range.upperBound - range.lowerBound)
                        value = (rawValue / step).rounded() * step
                    }
            )
        }
        .frame(minWidth: 80)
        .opacity(isEnabled ? 1 : 0.52)
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
