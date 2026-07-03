import SwiftUI

extension Text {
    func panelLabelFont(size: CGFloat, tracking: CGFloat) -> some View {
        self
            .font(.system(size: size, weight: .semibold))
            .kerning(tracking)
    }

    func panelMetricLabelFont() -> some View {
        self
            .font(.system(size: 12, weight: .medium))
            .kerning(0.15)
    }

    func panelTitleValueFont() -> some View {
        self
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .monospacedDigit()
    }

    func panelCaptionFont(size: CGFloat, weight: Font.Weight = .medium) -> some View {
        self
            .font(.system(size: size, weight: weight))
            .kerning(0.1)
    }

    func panelMonoFont(size: CGFloat, weight: Font.Weight) -> some View {
        self
            .font(.system(size: size, weight: weight, design: .monospaced))
            .monospacedDigit()
    }
}
