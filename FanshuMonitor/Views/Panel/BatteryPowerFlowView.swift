import SwiftUI

nonisolated struct BatteryPowerFlowPresentation: Equatable, Sendable {
    let isConnectedToPower: Bool
    let adapterInputWatts: Double?
    let systemLoadWatts: Double?
    let batteryWatts: Double?

    init(metrics: [MonitorMetric], isConnectedToPower: Bool) {
        self.isConnectedToPower = isConnectedToPower
        adapterInputWatts = Self.watts(metrics, named: "adapter-input")
        systemLoadWatts = Self.watts(metrics, named: "system-load")
        batteryWatts = Self.watts(metrics, named: "battery-flow")
    }

    var batteryIsSupplying: Bool {
        (batteryWatts ?? 0) < -0.05
    }

    var batteryMagnitude: Double? {
        batteryWatts.map(abs)
    }

    var systemFraction: Double {
        fraction(systemLoadWatts)
    }

    var batteryFraction: Double {
        fraction(batteryMagnitude)
    }

    var hasActiveFlow: Bool {
        [adapterInputWatts, systemLoadWatts, batteryMagnitude]
            .compactMap { $0 }
            .contains { $0 > 0.05 }
    }

    private var allocationTotal: Double {
        let input = max(adapterInputWatts ?? 0, 0)
        let allocated = max(systemLoadWatts ?? 0, 0) + (batteryIsSupplying ? 0 : max(batteryWatts ?? 0, 0))
        return max(input, allocated, batteryMagnitude ?? 0, 0.01)
    }

    private func fraction(_ value: Double?) -> Double {
        min(max((value ?? 0) / allocationTotal, 0), 1)
    }

    private static func watts(_ metrics: [MonitorMetric], named name: String) -> Double? {
        guard let value = metrics.first(where: { $0.name == name })?.value else {
            return nil
        }
        let normalized = value
            .replacingOccurrences(of: "W", with: "")
            .replacingOccurrences(of: "瓦", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != "--", let watts = Double(normalized), watts.isFinite else {
            return nil
        }
        return watts
    }
}

struct BatteryPowerFlowRow: View {
    let metrics: [MonitorMetric]
    let isConnectedToPower: Bool
    let theme: MonitorPanelTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: BatteryPowerFlowPresentation {
        BatteryPowerFlowPresentation(metrics: metrics, isConnectedToPower: isConnectedToPower)
    }

    private var tint: Color {
        theme.moduleTint(for: .battery)
    }

    var body: some View {
        VStack(spacing: 7) {
            Rectangle()
                .fill(theme.rowSeparator(for: .battery))
                .frame(height: 1)
                .padding(.leading, 28)

            HStack(spacing: 6) {
                flowNode(
                    title: presentation.isConnectedToPower
                        ? String(localized: "power-flow.input")
                        : String(localized: "power-flow.battery"),
                    value: presentation.isConnectedToPower
                        ? formatted(presentation.adapterInputWatts)
                        : formatted(presentation.batteryMagnitude),
                    symbol: presentation.isConnectedToPower ? "powerplug.fill" : "battery.75percent",
                    color: presentation.isConnectedToPower ? tint : .orange
                )
                .frame(width: 62)

                PowerFlowCanvas(
                    presentation: presentation,
                    tint: tint,
                    reduceMotion: reduceMotion
                )
                .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)

                VStack(spacing: 5) {
                    flowNode(
                        title: String(localized: "power-flow.system"),
                        value: formatted(presentation.systemLoadWatts),
                        symbol: "desktopcomputer",
                        color: tint
                    )

                    if presentation.isConnectedToPower {
                        flowNode(
                            title: presentation.batteryIsSupplying
                                ? String(localized: "power-flow.discharging")
                                : String(localized: "power-flow.charging"),
                            value: formatted(presentation.batteryMagnitude),
                            symbol: presentation.batteryIsSupplying ? "battery.75percent" : "battery.100percent.bolt",
                            color: presentation.batteryIsSupplying ? .orange : .green
                        )
                        .opacity((presentation.batteryMagnitude ?? 0) > 0.05 ? 1 : 0.48)
                    }
                }
                .frame(width: 76)
            }
            .padding(.leading, 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private func flowNode(title: String, value: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 11)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .panelCaptionFont(size: 9)
                    .foregroundStyle(theme.captionText)
                    .lineLimit(1)
                Text(value)
                    .panelMonoFont(size: 10, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            PanelPasteboard.copy(value)
        }
    }

    private func formatted(_ watts: Double?) -> String {
        guard let watts else { return "--" }
        return String(format: watts >= 100 ? "%.0f W" : "%.1f W", watts)
    }

    private var accessibilitySummary: String {
        let source = presentation.isConnectedToPower
            ? "\(String(localized: "power-flow.input")) \(formatted(presentation.adapterInputWatts))"
            : "\(String(localized: "power-flow.battery")) \(formatted(presentation.batteryMagnitude))"
        return "\(source), \(String(localized: "power-flow.system")) \(formatted(presentation.systemLoadWatts))"
    }
}

private struct PowerFlowCanvas: View {
    let presentation: BatteryPowerFlowPresentation
    let tint: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 15.0,
            paused: reduceMotion || !presentation.hasActiveFlow
        )) { timeline in
            Canvas { context, size in
                let phase = timeline.date.timeIntervalSinceReferenceDate * 0.72
                if presentation.isConnectedToPower {
                    drawAdapterFlow(in: &context, size: size, phase: phase)
                } else {
                    drawBatteryFlow(in: &context, size: size, phase: phase)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawAdapterFlow(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        let start = CGPoint(x: 1, y: size.height / 2)
        let junction = CGPoint(x: size.width * 0.34, y: size.height / 2)
        let systemEnd = CGPoint(x: size.width - 2, y: size.height * 0.25)
        let batteryEnd = CGPoint(x: size.width - 2, y: size.height * 0.75)

        drawLine(
            in: &context,
            from: start,
            to: junction,
            color: tint,
            width: 2.6,
            fraction: 1,
            phase: phase,
            reversed: false
        )
        drawCurve(
            in: &context,
            from: junction,
            to: systemEnd,
            color: tint,
            fraction: presentation.systemFraction,
            phase: phase,
            reversed: false
        )
        drawCurve(
            in: &context,
            from: junction,
            to: batteryEnd,
            color: presentation.batteryIsSupplying ? .orange : .green,
            fraction: presentation.batteryFraction,
            phase: phase,
            reversed: presentation.batteryIsSupplying
        )
    }

    private func drawBatteryFlow(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        drawLine(
            in: &context,
            from: CGPoint(x: 1, y: size.height / 2),
            to: CGPoint(x: size.width - 2, y: size.height / 2),
            color: .orange,
            width: 2.2 + 2.2 * presentation.systemFraction,
            fraction: presentation.systemFraction,
            phase: phase,
            reversed: false
        )
    }

    private func drawCurve(
        in context: inout GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        fraction: Double,
        phase: Double,
        reversed: Bool
    ) {
        let control1 = CGPoint(x: start.x + (end.x - start.x) * 0.44, y: start.y)
        let control2 = CGPoint(x: start.x + (end.x - start.x) * 0.58, y: end.y)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)

        let active = fraction > 0.005
        context.stroke(
            path,
            with: .color(color.opacity(active ? 0.74 : 0.14)),
            style: StrokeStyle(lineWidth: active ? 1.5 + 3.1 * fraction : 1.1, lineCap: .round)
        )
        guard active, !reduceMotion else { return }

        drawParticles(in: &context, phase: phase, reversed: reversed) { progress in
            cubicPoint(progress, start, control1, control2, end)
        } color: {
            color
        }
    }

    private func drawLine(
        in context: inout GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        width: Double,
        fraction: Double,
        phase: Double,
        reversed: Bool
    ) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let active = fraction > 0.005
        context.stroke(
            path,
            with: .color(color.opacity(active ? 0.74 : 0.14)),
            style: StrokeStyle(lineWidth: active ? width : 1.1, lineCap: .round)
        )
        guard active, !reduceMotion else { return }

        drawParticles(in: &context, phase: phase, reversed: reversed) { progress in
            CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
        } color: {
            color
        }
    }

    private func drawParticles(
        in context: inout GraphicsContext,
        phase: Double,
        reversed: Bool,
        point: (Double) -> CGPoint,
        color: () -> Color
    ) {
        for offset in [0.0, 0.5] {
            let rawProgress = (phase + offset).truncatingRemainder(dividingBy: 1)
            let progress = reversed ? 1 - rawProgress : rawProgress
            let center = point(progress)
            let rect = CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: rect), with: .color(color().opacity(0.96)))
        }
    }

    private func cubicPoint(
        _ progress: Double,
        _ start: CGPoint,
        _ control1: CGPoint,
        _ control2: CGPoint,
        _ end: CGPoint
    ) -> CGPoint {
        let t = CGFloat(progress)
        let inverse = 1 - t
        return CGPoint(
            x: inverse * inverse * inverse * start.x
                + 3 * inverse * inverse * t * control1.x
                + 3 * inverse * t * t * control2.x
                + t * t * t * end.x,
            y: inverse * inverse * inverse * start.y
                + 3 * inverse * inverse * t * control1.y
                + 3 * inverse * t * t * control2.y
                + t * t * t * end.y
        )
    }
}
