import AppKit
import Combine
import SwiftUI

struct MouseSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @ObservedObject var controller: MouseControlController

    var body: some View {
        SettingsPage {
            SettingsGroup(localized("mouse.group.enhancement")) {
                SettingsRow(title: localized("mouse.enhancement.enabled"), subtitle: localized("mouse.enhancement.subtitle")) {
                    Toggle("", isOn: $settings.mouseControlEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingsGroup(localized("mouse.group.device")) {
                SettingsRow(
                    title: localized("mouse.device.current"),
                    subtitle: controller.combinedStatusLine(locale: settings.languagePreference.locale ?? .current)
                ) {
                    Button {
                        controller.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.mouseControlEnabled)
                    .help(localized("mouse.device.refresh"))
                }

                SettingsDivider()

                SettingsRow(title: localized("mouse.dpi.on-demand"), subtitle: localized("mouse.dpi.on-demand.subtitle")) {
                    Toggle("", isOn: $settings.mouseDPIOnDemandEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                SettingsRow(title: "DPI", subtitle: localized("mouse.dpi.subtitle")) {
                    MouseDPIControl(
                        dpi: $settings.mouseDPI,
                        locale: settings.languagePreference.locale ?? .current,
                        isEnabled: settings.mouseControlEnabled,
                        isApplying: controller.isApplyingDPI
                    ) { dpi in
                        controller.applyDPI(dpi)
                    }
                }
            }

            SettingsGroup(localized("mouse.group.mapping")) {
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshButtonTapIfPossible()
        }
    }

    private func localized(_ key: String) -> String {
        MouseLocalization.string(key, locale: settings.languagePreference.locale ?? .current)
    }
}

private struct MouseDPIControl: View {
    @Binding var dpi: Double
    let locale: Locale
    let isEnabled: Bool
    let isApplying: Bool
    let apply: (Int) -> Void

    @State private var dpiText = ""
    @FocusState private var isDPIFieldFocused: Bool

    private let range: ClosedRange<Double> = 200...8000
    private let presets = [800, 1600, 2400, 4000, 8000]

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(spacing: 10) {
                MouseDPITrackSlider(
                    value: $dpi,
                    locale: locale,
                    range: range,
                    step: 50,
                    isEnabled: isEnabled && !isApplying
                )
                .frame(width: 190, height: 18)

                TextField("", text: $dpiText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .focused($isDPIFieldFocused)
                    .disabled(!isEnabled || isApplying)
                    .onSubmit {
                        commitDPIText()
                    }

                Button(MouseLocalization.string(isApplying ? "mouse.dpi.applying" : "mouse.dpi.apply", locale: locale)) {
                    commitDPIText()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
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
        .onAppear {
            syncDPIText(with: dpi)
        }
        .onChange(of: dpi) { _, newValue in
            guard !isDPIFieldFocused else { return }
            syncDPIText(with: newValue)
        }
        .onChange(of: isDPIFieldFocused) { _, isFocused in
            if isFocused {
                syncDPIText(with: dpi)
            }
        }
    }

    private func presetText(_ value: Int) -> String {
        guard value >= 1000 else {
            return "\(value)"
        }
        if value.isMultiple(of: 1000) {
            return "\(value / 1000)k"
        }
        let scaled = Double(value) / 1000
        return String(format: "%.1fk", scaled)
    }

    private func syncDPIText(with value: Double) {
        dpiText = "\(Int(value.rounded()))"
    }

    private func commitDPIText() {
        let digits = dpiText.filter(\.isNumber)
        guard let rawValue = Int(digits) else {
            syncDPIText(with: dpi)
            return
        }
        let clamped = min(Int(range.upperBound), max(Int(range.lowerBound), rawValue))
        dpi = Double(clamped)
        syncDPIText(with: dpi)
        apply(clamped)
        isDPIFieldFocused = false
    }
}

private struct MouseDPITrackSlider: View {
    @Binding var value: Double
    let locale: Locale
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
            .accessibilityElement()
            .accessibilityLabel(MouseLocalization.string("mouse.dpi.accessibility", locale: locale))
            .accessibilityValue("\(Int(clamped.rounded()))")
            .accessibilityAdjustableAction { direction in
                guard isEnabled else { return }
                let delta = direction == .increment ? step : -step
                value = min(range.upperBound, max(range.lowerBound, value + delta))
            }
        }
        .frame(minWidth: 80)
        .opacity(isEnabled ? 1 : 0.52)
    }
}

private struct MouseActionRow: View {
    @ObservedObject var settings: MonitorSettings
    let slot: MouseButtonSlot

    var body: some View {
        SettingsRow(title: slot.title(locale: settings.languagePreference.locale ?? .current), subtitle: nil) {
            HStack(spacing: 8) {
                if settings.mouseAction(for: slot) == .customShortcut {
                    MouseShortcutRecorderButton(
                        shortcut: shortcutBinding,
                        locale: settings.languagePreference.locale ?? .current
                    )
                }

                Picker(slot.title(locale: settings.languagePreference.locale ?? .current), selection: binding) {
                    ForEach(MouseButtonAction.allCases) { action in
                        Text(action.title(locale: settings.languagePreference.locale ?? .current)).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private var binding: Binding<MouseButtonAction> {
        Binding(
            get: { settings.mouseAction(for: slot) },
            set: { settings.setMouseAction($0, for: slot) }
        )
    }

    private var shortcutBinding: Binding<MouseKeyboardShortcut?> {
        Binding(
            get: { settings.mouseMapping(for: slot).shortcut },
            set: { settings.setMouseCustomShortcut($0, for: slot) }
        )
    }
}
