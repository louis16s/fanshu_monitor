import SwiftUI

enum PanelModuleHeaderMetrics {
    static let iconSize: CGFloat = 13
    static let iconSlotWidth: CGFloat = 18
    static let contentSpacing: CGFloat = 10
    static let textSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 8
}

struct PanelModuleIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: PanelModuleHeaderMetrics.iconSize, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .frame(width: PanelModuleHeaderMetrics.iconSlotWidth)
    }
}

struct PanelModuleHeader<Leading: View, Trailing: View>: View {
    let title: String
    let value: String
    let titleColor: Color
    let valueColor: Color
    private let leading: Leading
    private let trailing: Trailing

    init(
        title: String,
        value: String,
        titleColor: Color,
        valueColor: Color,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.value = value
        self.titleColor = titleColor
        self.valueColor = valueColor
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: PanelModuleHeaderMetrics.contentSpacing) {
            leading
                .frame(width: PanelModuleHeaderMetrics.iconSlotWidth)

            HStack(spacing: PanelModuleHeaderMetrics.textSpacing) {
                Text(title)
                    .panelMetricLabelFont()
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: true, vertical: false)

                Text(value)
                    .panelTitleValueFont()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .lineLimit(1)
            .layoutPriority(2)

            Spacer(minLength: 8)

            trailing
                .layoutPriority(1)
        }
        .padding(.horizontal, PanelModuleHeaderMetrics.horizontalPadding)
        .padding(.vertical, PanelModuleHeaderMetrics.verticalPadding)
    }
}
