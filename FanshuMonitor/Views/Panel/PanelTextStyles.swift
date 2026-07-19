import SwiftUI

enum PanelTypography {
    static let moduleHeaderSize: CGFloat = 12
    static let moduleHeaderWeight: Font.Weight = .semibold
}

extension Text {
    func panelLabelFont(size: CGFloat, tracking: CGFloat) -> some View {
        self
            .font(.system(size: size, weight: .semibold))
            .kerning(tracking)
    }

    func panelMetricLabelFont() -> some View {
        self
            .font(.system(
                size: PanelTypography.moduleHeaderSize,
                weight: PanelTypography.moduleHeaderWeight
            ))
    }

    func panelTitleValueFont() -> some View {
        self
            .font(.system(
                size: PanelTypography.moduleHeaderSize,
                weight: PanelTypography.moduleHeaderWeight
            ))
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
