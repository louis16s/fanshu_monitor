import AppKit
import Combine
import CoreGraphics
import OSLog
import SwiftUI

struct DisplayControlsSection: View {
    @ObservedObject var settings: MonitorSettings
    @ObservedObject var controller: DisplayControlController
    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded = true

    private let expansionAnimation = Animation.smooth(duration: 0.22)

    var body: some View {
        let palette = MonitorPalette(
            preference: settings.colorSchemePreference,
            colorScheme: colorScheme
        )
        let tint = palette.displayTint
        let visibleDisplays = controller.displays
                .filter { settings.showBuiltInDisplays || !$0.isBuiltIn }
                .sorted { $0.isBuiltIn && !$1.isBuiltIn }
        let hasControls = settings.displayBrightnessControlEnabled
            || settings.displayVolumeControlEnabled
            || settings.displayContrastControlEnabled

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "display")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(tint)
                    .frame(width: 18)

                Text("Display:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                Text(summary(for: visibleDisplays, hasControls: hasControls))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.valueText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.captionText)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .animation(expansionAnimation, value: isExpanded)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(expansionAnimation) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                detailContent(
                    visibleDisplays: visibleDisplays,
                    hasControls: hasControls,
                    palette: palette,
                    tint: tint
                )
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
                .transition(.detailDisclosure)
            }
        }
        .onAppear {
            controller.refreshAsync()
            controller.startAutomaticRefresh()
        }
        .animation(expansionAnimation, value: isExpanded)
        .glassEffect(.regular.tint(palette.displayGlassTint), in: .rect(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func detailContent(
        visibleDisplays: [ControlledDisplay],
        hasControls: Bool,
        palette: MonitorPalette,
        tint: Color
    ) -> some View {
        if !hasControls {
            DisplayEmptyState(text: "设置中未启用控制项", palette: palette)
        } else if visibleDisplays.isEmpty {
            DisplayEmptyState(text: settings.showBuiltInDisplays ? "未发现显示器" : "未发现外接显示器", palette: palette)
        } else {
            VStack(spacing: 6) {
                Rectangle()
                    .fill(palette.displaySeparator)
                    .frame(height: 1)
                    .padding(.leading, 24)

                ForEach(Array(visibleDisplays.enumerated()), id: \.element.id) { index, display in
                    if index > 0 {
                        Rectangle()
                            .fill(palette.displaySeparator.opacity(0.72))
                            .frame(height: 1)
                            .padding(.leading, 24)
                    }

                    DisplayControlGroup(
                        display: display,
                        settings: settings,
                        controller: controller,
                        palette: palette,
                        tint: tint
                    )
                }
            }
        }
    }

    private func summary(for displays: [ControlledDisplay], hasControls: Bool) -> String {
        guard hasControls else {
            return "Off"
        }

        let externalCount = displays.filter { !$0.isBuiltIn }.count
        if externalCount > 0 {
            return "外接 \(externalCount)"
        }
        return "内置"
    }
}

private extension AnyTransition {
    static var detailDisclosure: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .opacity
        )
    }
}

private struct DisplayControlGroup: View {
    let display: ControlledDisplay
    @ObservedObject var settings: MonitorSettings
    @ObservedObject var controller: DisplayControlController
    let palette: MonitorPalette
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
                .frame(width: 13)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(display.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(display.name)

                    Spacer(minLength: 8)

                    if display.isBuiltIn {
                        Button {
                            controller.toggleBuiltInBlackout(displayID: display.id)
                        } label: {
                            Text(controller.isBuiltInBlackoutEnabled(displayID: display.id) ? "恢复" : "关闭")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(controller.isBuiltInBlackoutEnabled(displayID: display.id) ? tint : palette.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background {
                            Capsule()
                                .fill(controller.isBuiltInBlackoutEnabled(displayID: display.id) ? tint.opacity(0.16) : palette.displayBadgeFill)
                        }
                        .help(controller.isBuiltInBlackoutEnabled(displayID: display.id) ? "恢复内建显示器" : "关闭内建显示器")
                    }

                    Text(display.isBuiltIn ? "内置" : "外接")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background {
                            Capsule()
                                .fill(palette.displayBadgeFill)
                        }
                }

                VStack(spacing: 5) {
                    if settings.displayBrightnessControlEnabled {
                        DisplayControlSlider(
                            label: "亮度",
                            systemImage: "sun.max",
                            value: binding(for: .brightness),
                            isEnabled: display.supports(.brightness),
                            hardwareZeroPercent: display.isBuiltIn || !settings.displaySoftwareDimmingEnabled
                                ? nil
                                : DisplayDimmingCalibration.hardwareZeroUserBrightness,
                            palette: palette,
                            tint: tint
                        )

                    }

                    if settings.displayVolumeControlEnabled {
                        DisplayControlSlider(
                            label: "音量",
                            systemImage: "speaker.wave.2",
                            value: binding(for: .volume),
                            isEnabled: display.supports(.volume),
                            hardwareZeroPercent: nil,
                            palette: palette,
                            tint: tint
                        )
                    }

                    if settings.displayContrastControlEnabled {
                        DisplayControlSlider(
                            label: "对比度",
                            systemImage: "circle.lefthalf.filled",
                            value: binding(for: .contrast),
                            isEnabled: display.supports(.contrast),
                            hardwareZeroPercent: nil,
                            palette: palette,
                            tint: tint
                        )
                    }
                }

                if settings.displayAvailabilityHintsEnabled {
                    ControlAvailabilityGrid(display: display, palette: palette)
                }
            }
        }
        .padding(.leading, 24)
    }

    private func binding(for control: DisplayControlKind) -> Binding<Double> {
        Binding(
            get: { controller.value(for: control, displayID: display.id) },
            set: { controller.setValueAsync($0, for: control, displayID: display.id) }
        )
    }

}

private struct ControlAvailabilityGrid: View {
    let display: ControlledDisplay
    let palette: MonitorPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            availability("亮度", supported: display.supportsBrightness, reason: display.brightnessUnavailableReason)
            availability("音量", supported: display.supportsVolume, reason: display.volumeUnavailableReason)
            availability("对比度", supported: display.supportsContrast, reason: display.contrastUnavailableReason)
        }
        .padding(.top, 2)
    }

    private func availability(_ name: String, supported: Bool, reason: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(supported ? .green : palette.captionText)
            Text(supported ? "\(name) 可用" : "\(name) 不可用: \(reason ?? "--")")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(palette.captionText)
                .lineLimit(1)
        }
    }
}

private struct DisplayControlSlider: View {
    let label: String
    let systemImage: String
    @Binding var value: Double
    let isEnabled: Bool
    let hardwareZeroPercent: Double?
    let palette: MonitorPalette
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isEnabled ? tint : palette.captionText)
                .frame(width: 13)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isEnabled ? palette.secondaryText : palette.captionText)
                .frame(width: 30, alignment: .leading)

            DisplayTrackSlider(
                value: $value,
                isEnabled: isEnabled,
                hardwareZeroPercent: hardwareZeroPercent,
                palette: palette,
                tint: tint
            )
            .frame(height: hardwareZeroPercent == nil ? 18 : 28)

            Text("\(Int(value.rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isEnabled ? palette.secondaryText : palette.captionText)
                .frame(width: 32, alignment: .trailing)
        }
        .opacity(isEnabled ? 1 : 0.48)
    }
}

private struct DisplayTrackSlider: View {
    @Binding var value: Double
    let isEnabled: Bool
    let hardwareZeroPercent: Double?
    let palette: MonitorPalette
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let trackHeight: CGFloat = 5
            let thumbSize: CGFloat = 16
            let width = max(thumbSize, proxy.size.width)
            let clampedValue = min(100, max(0, value))
            let fillWidth = width * clampedValue / 100
            let thumbX = width * clampedValue / 100

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(inactiveTrackFill)
                    .frame(height: trackHeight)
                    .overlay {
                        Capsule()
                            .stroke(palette.captionText.opacity(0.12), lineWidth: 0.7)
                    }
                    .offset(y: 7)

                Capsule()
                    .fill(isEnabled ? tint : palette.captionText)
                    .frame(width: fillWidth, height: trackHeight)
                    .offset(y: 7)

                if let hardwareZeroPercent {
                    hardwareZeroMark(
                        percent: hardwareZeroPercent,
                        width: width,
                        trackHeight: trackHeight
                    )
                }

                Circle()
                    .fill(isEnabled ? Color(nsColor: .controlBackgroundColor) : palette.captionText.opacity(0.9))
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.22), radius: 2.5, x: 0, y: 1)
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.45), lineWidth: 0.6)
                    }
                    .offset(x: min(max(0, thumbX - thumbSize / 2), width - thumbSize), y: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        let percentage = min(100, max(0, gesture.location.x / width * 100))
                        value = percentage.rounded()
                    }
            )
        }
        .frame(minWidth: 80)
    }

    private func hardwareZeroMark(percent: Double, width: CGFloat, trackHeight: CGFloat) -> some View {
        let clamped = min(100, max(0, percent))
        let x = width * clamped / 100
        let label = "DDC 0 · \(Int(clamped.rounded()))%"

        return VStack(spacing: 1) {
            Rectangle()
                .fill(palette.captionText.opacity(0.74))
                .frame(width: 1, height: 8)

            Text(label)
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.captionText.opacity(0.92))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: 54)
        .offset(x: min(max(0, x - 27), max(0, width - 54)), y: 12)
        .allowsHitTesting(false)
    }

    private var inactiveTrackFill: Color {
        palette.captionText.opacity(isEnabled ? 0.18 : 0.12)
    }
}

private struct DisplayEmptyState: View {
    let text: String
    let palette: MonitorPalette

    var body: some View {
        VStack(spacing: 7) {
            Rectangle()
                .fill(palette.displaySeparator)
                .frame(height: 1)
                .padding(.leading, 28)

            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.captionText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28)
        }
    }
}

