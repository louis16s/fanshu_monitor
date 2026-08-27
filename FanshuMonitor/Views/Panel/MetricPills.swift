import SwiftUI

struct MetricPill: View {
    let systemImage: String
    let text: String
    let theme: MonitorPanelTheme

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: 72, alignment: .trailing)
    }
}
