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

struct NetworkRatePill: View {
    let systemImage: String
    let text: String
    let theme: MonitorPanelTheme

    private var parts: (value: String, unit: String) {
        guard let split = text.lastIndex(of: " ") else {
            return (text, "")
        }

        return (
            String(text[..<split]),
            String(text[text.index(after: split)...])
        )
    }

    var body: some View {
        let parts = parts

        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 10)

            Text(parts.value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(minWidth: 8, maxWidth: 30, alignment: .trailing)

            Text(parts.unit)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 26, alignment: .leading)
        }
        .foregroundStyle(theme.secondaryText)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 48, maxWidth: 68, alignment: .trailing)
    }
}
