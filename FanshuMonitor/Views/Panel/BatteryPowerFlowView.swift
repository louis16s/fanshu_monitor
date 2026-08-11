import AppKit
import QuartzCore
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

    private static func watts(_ metrics: [MonitorMetric], named name: MetricID) -> Double? {
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

nonisolated enum PowerFlowAnimationPolicy {
    static let cycleDuration: TimeInterval = 1.15

    static func endpointY(height: Double) -> (system: Double, battery: Double) {
        (height * 0.75, height * 0.25)
    }

    static func shouldAnimate(
        isActive: Bool,
        reduceMotion: Bool,
        hasActiveFlow: Bool
    ) -> Bool {
        isActive && !reduceMotion && hasActiveFlow
    }
}

struct BatteryPowerFlowRow: View {
    let metrics: [MonitorMetric]
    let isConnectedToPower: Bool
    let isActive: Bool
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
                    isActive: isActive,
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

private struct PowerFlowCanvas: NSViewRepresentable {
    let presentation: BatteryPowerFlowPresentation
    let tint: Color
    let isActive: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> PowerFlowLayerView {
        PowerFlowLayerView()
    }

    func updateNSView(_ view: PowerFlowLayerView, context: Context) {
        view.configure(
            presentation: presentation,
            tint: NSColor(tint),
            shouldAnimate: PowerFlowAnimationPolicy.shouldAnimate(
                isActive: isActive,
                reduceMotion: reduceMotion,
                hasActiveFlow: presentation.hasActiveFlow
            )
        )
    }
}

private final class PowerFlowParticleLayer: CAReplicatorLayer {
    let particle = CALayer()
    var animationDirection = 0
    var animationBounds = CGRect.null

    override init() {
        super.init()
        instanceCount = 3
        instanceDelay = PowerFlowAnimationPolicy.cycleDuration / 3
        addSublayer(particle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class PowerFlowLayerView: NSView {
    private let trunkTrack = CAShapeLayer()
    private let systemTrack = CAShapeLayer()
    private let batteryTrack = CAShapeLayer()
    private let trunkFlow = PowerFlowParticleLayer()
    private let systemFlow = PowerFlowParticleLayer()
    private let batteryFlow = PowerFlowParticleLayer()

    private var presentation: BatteryPowerFlowPresentation?
    private var tint = NSColor.controlAccentColor
    private var shouldAnimate = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        [trunkTrack, systemTrack, batteryTrack].forEach {
            $0.fillColor = nil
            $0.lineCap = .round
            layer?.addSublayer($0)
        }
        [trunkFlow, systemFlow, batteryFlow].forEach {
            layer?.addSublayer($0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updatePaths()
    }

    func configure(
        presentation: BatteryPowerFlowPresentation,
        tint: NSColor,
        shouldAnimate: Bool
    ) {
        self.presentation = presentation
        self.tint = tint
        self.shouldAnimate = shouldAnimate
        updatePaths()
    }

    private func updatePaths() {
        guard let presentation, bounds.width > 4, bounds.height > 4 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        [trunkFlow, systemFlow, batteryFlow].forEach { $0.frame = bounds }

        let start = CGPoint(x: 1, y: bounds.midY)
        let end = CGPoint(x: bounds.maxX - 2, y: bounds.midY)
        if presentation.isConnectedToPower {
            let junction = CGPoint(x: bounds.width * 0.34, y: bounds.midY)
            // Core Animation uses a bottom-left origin while SwiftUI places the
            // system label above the battery label.
            let endpointY = PowerFlowAnimationPolicy.endpointY(height: bounds.height)
            let systemEnd = CGPoint(x: end.x, y: endpointY.system)
            let batteryEnd = CGPoint(x: end.x, y: endpointY.battery)
            let trunkPath = linePath(from: start, to: junction)
            let systemPath = curvePath(from: junction, to: systemEnd)
            let batteryPath = curvePath(from: junction, to: batteryEnd)
            setBranch(
                track: trunkTrack,
                flow: trunkFlow,
                path: trunkPath,
                color: tint,
                width: 2.2,
                active: (presentation.adapterInputWatts ?? 0) > 0.05,
                reversed: false
            )
            setBranch(
                track: systemTrack,
                flow: systemFlow,
                path: systemPath,
                color: tint,
                width: 1.2 + 2.0 * presentation.systemFraction,
                active: presentation.systemFraction > 0.005,
                reversed: false
            )
            setBranch(
                track: batteryTrack,
                flow: batteryFlow,
                path: batteryPath,
                color: presentation.batteryIsSupplying ? .systemOrange : .systemGreen,
                width: 1.2 + 2.0 * presentation.batteryFraction,
                active: presentation.batteryFraction > 0.005,
                reversed: presentation.batteryIsSupplying
            )
        } else {
            setBranch(
                track: trunkTrack,
                flow: trunkFlow,
                path: linePath(from: start, to: end),
                color: .systemOrange,
                width: 1.4 + 1.8 * presentation.systemFraction,
                active: presentation.systemFraction > 0.005,
                reversed: false
            )
            hideBranch(track: systemTrack, flow: systemFlow)
            hideBranch(track: batteryTrack, flow: batteryFlow)
        }
        CATransaction.commit()
    }

    private func setBranch(
        track: CAShapeLayer,
        flow: PowerFlowParticleLayer,
        path: CGPath,
        color: NSColor,
        width: CGFloat,
        active: Bool,
        reversed: Bool
    ) {
        track.path = path
        track.strokeColor = color.withAlphaComponent(active ? 0.58 : 0.12).cgColor
        track.lineWidth = active ? width : 1.1
        track.isHidden = false

        flow.isHidden = !active || !shouldAnimate
        let particleSize = min(4.0, max(2.8, width + 0.8))
        flow.particle.bounds = CGRect(x: 0, y: 0, width: particleSize, height: particleSize)
        flow.particle.cornerRadius = particleSize / 2
        flow.particle.backgroundColor = color.withAlphaComponent(0.96).cgColor
        flow.particle.shadowColor = color.cgColor
        flow.particle.shadowOpacity = 0.42
        flow.particle.shadowRadius = 2
        flow.particle.shadowOffset = .zero
        if flow.isHidden {
            flow.particle.removeAnimation(forKey: "power-flow")
            flow.animationDirection = 0
        } else {
            animate(flow, path: reversed ? reversedPath(path) : path, reversed: reversed)
        }
    }

    private func hideBranch(track: CAShapeLayer, flow: PowerFlowParticleLayer) {
        track.isHidden = true
        flow.isHidden = true
        flow.particle.removeAnimation(forKey: "power-flow")
        flow.animationDirection = 0
    }

    private func animate(_ layer: PowerFlowParticleLayer, path: CGPath, reversed: Bool) {
        let direction = reversed ? -1 : 1
        let pathBounds = path.boundingBoxOfPath
        guard layer.animationDirection != direction
                || layer.animationBounds != pathBounds
                || layer.particle.animation(forKey: "power-flow") == nil else {
            return
        }
        layer.animationDirection = direction
        layer.animationBounds = pathBounds
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.path = path
        animation.calculationMode = .paced
        animation.duration = PowerFlowAnimationPolicy.cycleDuration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        layer.particle.add(animation, forKey: "power-flow")
    }

    private func linePath(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    private func curvePath(from start: CGPoint, to end: CGPoint) -> CGPath {
        let control1 = CGPoint(x: start.x + (end.x - start.x) * 0.44, y: start.y)
        let control2 = CGPoint(x: start.x + (end.x - start.x) * 0.58, y: end.y)
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }

    private func reversedPath(_ path: CGPath) -> CGPath {
        var elements: [(CGPathElementType, [CGPoint])] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let count = switch element.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            case .closeSubpath: 0
            @unknown default: 0
            }
            elements.append((element.type, Array(UnsafeBufferPointer(start: element.points, count: count))))
        }
        guard let start = elements.last?.1.last else { return path }
        let reversed = CGMutablePath()
        reversed.move(to: start)
        for element in elements.reversed() {
            switch element.0 {
            case .moveToPoint:
                continue
            case .addLineToPoint:
                if let end = elements.first?.1.first {
                    reversed.addLine(to: end)
                }
            case .addCurveToPoint:
                guard element.1.count == 3,
                      let end = elements.first?.1.first else { continue }
                reversed.addCurve(
                    to: end,
                    control1: element.1[1],
                    control2: element.1[0]
                )
            default:
                continue
            }
        }
        return reversed
    }
}
