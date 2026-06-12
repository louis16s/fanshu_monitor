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

                Text("显示器:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                Text(summary(for: visibleDisplays, hasControls: hasControls))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
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
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
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
            VStack(spacing: 8) {
                Rectangle()
                    .fill(palette.displaySeparator)
                    .frame(height: 1)
                    .padding(.leading, 28)

                ForEach(Array(visibleDisplays.enumerated()), id: \.element.id) { index, display in
                    if index > 0 {
                        Rectangle()
                            .fill(palette.displaySeparator.opacity(0.72))
                            .frame(height: 1)
                            .padding(.leading, 28)
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
            return "已关闭"
        }

        let externalCount = displays.filter { !$0.isBuiltIn }.count
        if externalCount > 0 {
            return "\(displays.count) 台 · 外接 \(externalCount)"
        }
        return "\(displays.count) 台"
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(display.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(display.name)

                    Spacer(minLength: 8)

                    Text(display.isBuiltIn ? "内置" : "外接")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(palette.displayBadgeFill)
                        }
                }

                VStack(spacing: 7) {
                    if settings.displayBrightnessControlEnabled {
                        DisplayControlSlider(
                            label: "亮度",
                            systemImage: "sun.max",
                            value: binding(for: .brightness),
                            isEnabled: display.supports(.brightness),
                            palette: palette,
                            tint: tint
                        )

                        if !display.isBuiltIn {
                            HiDPIButton(
                                display: display,
                                showReason: settings.displayAvailabilityHintsEnabled,
                                palette: palette,
                                tint: tint
                            ) {
                                controller.toggleHiDPI(displayID: display.id)
                            }
                        }
                    }

                    if settings.displayVolumeControlEnabled {
                        DisplayControlSlider(
                            label: "音量",
                            systemImage: "speaker.wave.2",
                            value: binding(for: .volume),
                            isEnabled: display.supports(.volume),
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
        .padding(.leading, 28)
    }

    private func binding(for control: DisplayControlKind) -> Binding<Double> {
        Binding(
            get: { controller.value(for: control, displayID: display.id) },
            set: { controller.setValueAsync($0, for: control, displayID: display.id) }
        )
    }
}

private struct HiDPIButton: View {
    let display: ControlledDisplay
    let showReason: Bool
    let palette: MonitorPalette
    let tint: Color
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: display.hidpiEnabled ? "textformat.size.larger" : "textformat.size")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(display.supportsHiDPI ? tint : palette.captionText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!display.supportsHiDPI)
            .help(display.supportsHiDPI ? "开启或关闭 HiDPI" : (display.hidpiUnavailableReason ?? "HiDPI 不可用"))

            Text("HiDPI")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(display.supportsHiDPI ? palette.secondaryText : palette.captionText)

            if showReason, !display.supportsHiDPI, let reason = display.hidpiUnavailableReason {
                Text(reason)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.captionText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if display.supportsHiDPI, let detail = display.hidpiModeDescription {
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.captionText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .opacity(display.supportsHiDPI ? 1 : 0.62)
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
            Text(supported ? "\(name) 可用" : "\(name) 不可用：\(reason ?? "--")")
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
    let palette: MonitorPalette
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isEnabled ? tint : palette.captionText)
                .frame(width: 14)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isEnabled ? palette.secondaryText : palette.captionText)
                .frame(width: 34, alignment: .leading)

            Slider(value: $value, in: 0...100, step: 1)
                .tint(tint)
                .controlSize(.small)
                .disabled(!isEnabled)

            Text("\(Int(value.rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isEnabled ? palette.secondaryText : palette.captionText)
                .frame(width: 34, alignment: .trailing)
        }
        .opacity(isEnabled ? 1 : 0.48)
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

@MainActor
final class DisplayControlController: ObservableObject {
    @Published private(set) var displays: [ControlledDisplay] = []
    @Published private var pendingValues: [CGDirectDisplayID: [DisplayControlKind: Double]] = [:]

    private let service = DisplayControlService()
    private let modeService = DisplayModeService()
    private let worker = DisplayControlWorker()
    private var fallbackValues: [CGDirectDisplayID: [DisplayControlKind: Double]] = [:]
    private var screenChangeObserver: NSObjectProtocol?
    private var refreshWorkItem: DispatchWorkItem?
    private var displayCallbackRegistered = false

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func refreshAsync() {
        worker.refresh(service: service) { detectedDisplays in
            DispatchQueue.main.async {
                AppLogger.ui.info("Display refresh completed, found \(detectedDisplays.count) displays")
                self.displays = detectedDisplays
                for display in detectedDisplays {
                    self.seedFallbackValues(for: display)
                }
            }
        }
    }

    func refreshNow() {
        refreshWorkItem?.cancel()
        refreshAsync()
    }

    func refreshSynchronously() {
        refreshWorkItem?.cancel()
        let detectedDisplays = service.displays()
        AppLogger.ui.info("Synchronous display refresh completed, found \(detectedDisplays.count) displays")
        displays = detectedDisplays
        for display in detectedDisplays {
            seedFallbackValues(for: display)
        }
    }

    func startAutomaticRefresh() {
        if screenChangeObserver == nil {
            screenChangeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let controller = self else { return }
                Task { @MainActor in
                    controller.scheduleRefresh()
                }
            }
        }

        guard !displayCallbackRegistered else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        if CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, pointer) == .success {
            displayCallbackRegistered = true
        }
    }

    func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshAsync()
            }
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    func displayUnderMouse() -> ControlledDisplay? {
        guard let displayID = displayIDsUnderMouse().first else { return nil }
        if displays.isEmpty {
            refreshNow()
        }
        return displays.first { $0.id == displayID }
    }

    func brightnessDisplayUnderMouse() -> ControlledDisplay? {
        let candidateIDs = displayIDsUnderMouse()
        guard !candidateIDs.isEmpty else {
            AppLogger.ui.debug("Brightness key pass-through: no display under mouse")
            return nil
        }
        if displays.isEmpty {
            AppLogger.ui.debug("Brightness key target list is empty; scheduling display refresh")
            refreshNow()
            return nil
        }

        if let target = brightnessTarget(from: candidateIDs) {
            return target
        }

        AppLogger.ui.debug("Brightness key target not ready; scheduling display refresh")
        refreshNow()

        if candidateIDs.contains(where: { candidateID in
            displays.first(where: { $0.id == candidateID })?.isBuiltIn == true
        }) {
            AppLogger.ui.debug("Brightness key pass-through: mouse is on built-in display")
            return nil
        }

        AppLogger.ui.debug("Brightness key pass-through: no controllable external display under mouse")
        return nil
    }

    private func brightnessTarget(from candidateIDs: [CGDirectDisplayID]) -> ControlledDisplay? {
        for displayID in candidateIDs {
            guard let display = displays.first(where: { $0.id == displayID }) else {
                AppLogger.ui.debug("Brightness key candidate \(displayID) is not in controller list")
                continue
            }
            if display.isBuiltIn {
                continue
            }
            if display.supports(.brightness) {
                return display
            }
            AppLogger.ui.debug(
                "Brightness key candidate \(displayID) does not support brightness, reason: \(display.brightnessUnavailableReason ?? "unknown", privacy: .public)"
            )
        }
        return nil
    }

    private func displayIDsUnderMouse() -> [CGDirectDisplayID] {
        let mouseLocation = NSEvent.mouseLocation
        var candidates: [CGDirectDisplayID] = []

        func append(_ displayID: CGDirectDisplayID?) {
            guard let displayID, displayID != 0, !candidates.contains(displayID) else { return }
            candidates.append(displayID)
        }

        func appendMirroredDisplays(for displayID: CGDirectDisplayID) {
            let mirroredSource = CGDisplayMirrorsDisplay(displayID)
            if mirroredSource != 0 {
                append(mirroredSource)
            }

            for display in displays where CGDisplayMirrorsDisplay(display.id) == displayID {
                append(display.id)
            }
        }

        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }),
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            append(displayID)
            appendMirroredDisplays(for: displayID)
        }

        for point in mousePointCandidates(appKitPoint: mouseLocation) {
            var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
            var displayCount: UInt32 = 0
            if CGGetDisplaysWithPoint(point, UInt32(displayIDs.count), &displayIDs, &displayCount) == .success, displayCount > 0 {
                for displayID in displayIDs.prefix(Int(displayCount)) {
                    append(displayID)
                    appendMirroredDisplays(for: displayID)
                }
            }

            for display in displays where CGDisplayBounds(display.id).contains(point) {
                append(display.id)
                appendMirroredDisplays(for: display.id)
            }
        }

        return candidates
    }

    private func mousePointCandidates(appKitPoint: CGPoint) -> [CGPoint] {
        var points = [appKitPoint]
        if let eventLocation = CGEvent(source: nil)?.location {
            points.append(eventLocation)
        }

        let frames = NSScreen.screens.map(\.frame)
        if let minY = frames.map(\.minY).min(),
           let maxY = frames.map(\.maxY).max() {
            points.append(CGPoint(x: appKitPoint.x, y: minY + maxY - appKitPoint.y))
        }

        var unique: [CGPoint] = []
        for point in points where !unique.contains(where: { abs($0.x - point.x) < 0.5 && abs($0.y - point.y) < 0.5 }) {
            unique.append(point)
        }
        return unique
    }

    func value(for control: DisplayControlKind, displayID: CGDirectDisplayID) -> Double {
        if let pendingValue = pendingValues[displayID]?[control] {
            return pendingValue
        }

        if let display = displays.first(where: { $0.id == displayID }) {
            return display.value(for: control)
        }

        return fallbackValues[displayID]?[control] ?? control.defaultValue
    }

    func setValueAsync(_ value: Double, for control: DisplayControlKind, displayID: CGDirectDisplayID) {
        setValue(value, for: control, displayID: displayID, markUnsupportedOnFailure: true)
    }

    func setKeyboardBrightnessValue(_ value: Double, displayID: CGDirectDisplayID) {
        setValue(value, for: .brightness, displayID: displayID, markUnsupportedOnFailure: false)
    }

    private func setValue(
        _ value: Double,
        for control: DisplayControlKind,
        displayID: CGDirectDisplayID,
        markUnsupportedOnFailure: Bool
    ) {
        let clampedValue = min(100, max(0, value))
        guard let display = displays.first(where: { $0.id == displayID }) else {
            AppLogger.ui.error("Display not found for setValue: \(displayID)")
            return
        }
        guard display.supports(control) else {
            AppLogger.ui.error("Display \(displayID) does not support control: \(control.storageKey, privacy: .public)")
            return
        }

        let key = ControlKey(displayID: displayID, control: control)
        pendingValues[displayID, default: [:]][control] = clampedValue
        worker.setValue(clampedValue, for: key, display: display, service: service) { [weak self] result in
            Task { @MainActor in
                self?.handleWriteResult(result, markUnsupportedOnFailure: markUnsupportedOnFailure)
            }
        }
    }

    func toggleHiDPI(displayID: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == displayID }), display.supportsHiDPI else {
            return
        }

        let targetEnabled = !display.hidpiEnabled
        if modeService.setHiDPIEnabled(targetEnabled, for: displayID) {
            refreshNow()
        } else {
            AppLogger.ui.error("Failed to set HiDPI \(targetEnabled, privacy: .public) for display \(displayID, privacy: .public)")
        }
    }

    private func seedFallbackValues(for display: ControlledDisplay) {
        fallbackValues[display.id] = [
            .brightness: display.brightness,
            .volume: display.volume,
            .contrast: display.contrast
        ]
    }

    private func updateLocalValue(_ value: Double, for control: DisplayControlKind, displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
            return
        }

        displays[index].setValue(value, for: control)
    }

    private func handleWriteResult(_ result: DisplayWriteResult, markUnsupportedOnFailure: Bool) {
        let currentPendingValue = pendingValues[result.key.displayID]?[result.key.control]
        let isCurrentResult = currentPendingValue.map { abs($0 - result.value) < 0.001 } ?? false

        if result.success {
            updateLocalValue(result.value, for: result.key.control, displayID: result.key.displayID)
            fallbackValues[result.key.displayID, default: [:]][result.key.control] = result.value
            AppLogger.ui.debug("Write succeeded for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public)")
        } else {
            AppLogger.ui.error("Write failed for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public)")
            if isCurrentResult, markUnsupportedOnFailure {
                markControlUnsupported(result.key.control, displayID: result.key.displayID)
            }
        }

        guard isCurrentResult else {
            return
        }

        pendingValues[result.key.displayID]?[result.key.control] = nil
        if pendingValues[result.key.displayID]?.isEmpty == true {
            pendingValues[result.key.displayID] = nil
        }
    }

    private func markControlUnsupported(_ control: DisplayControlKind, displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
            return
        }

        displays[index].setSupported(false, for: control)
    }
}

private final class DisplayControlWorker {
    private let queue = DispatchQueue(label: "fanshu.ddc", qos: .userInitiated)
    private var pendingWrites: [ControlKey: Double] = [:]
    private var debounceTimers: [ControlKey: DispatchWorkItem] = [:]
    private let debounceInterval: DispatchTimeInterval = .milliseconds(150)

    func refresh(service: DisplayControlService, completion: @escaping ([ControlledDisplay]) -> Void) {
        queue.async {
            completion(service.displays())
        }
    }

    func setValue(
        _ value: Double,
        for key: ControlKey,
        display: ControlledDisplay,
        service: DisplayControlService,
        completion: @escaping (DisplayWriteResult) -> Void
    ) {
        queue.async {
            self.pendingWrites[key] = value

            self.debounceTimers[key]?.cancel()
            let timer = DispatchWorkItem { [service, display, key, completion] in
                guard let latestValue = self.pendingWrites.removeValue(forKey: key) else {
                    return
                }
                self.debounceTimers.removeValue(forKey: key)

                let success = service.setValue(latestValue, for: key.control, display: display)
                completion(DisplayWriteResult(key: key, value: latestValue, success: success))
            }
            self.debounceTimers[key] = timer
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: timer)
        }
    }
}

private nonisolated struct DisplayWriteResult {
    let key: ControlKey
    let value: Double
    let success: Bool
}

struct ControlledDisplay: Identifiable {
    let id: CGDirectDisplayID
    let storageID: String
    let name: String
    let isBuiltIn: Bool
    var supportsBrightness: Bool
    var supportsVolume: Bool
    var supportsContrast: Bool
    var supportsHiDPI: Bool
    var brightness: Double
    var volume: Double
    var contrast: Double
    var hidpiEnabled: Bool
    var hidpiModeDescription: String?
    var brightnessUnavailableReason: String?
    var volumeUnavailableReason: String?
    var contrastUnavailableReason: String?
    var hidpiUnavailableReason: String?

    func supports(_ control: DisplayControlKind) -> Bool {
        switch control {
        case .brightness:
            supportsBrightness
        case .volume:
            supportsVolume
        case .contrast:
            supportsContrast
        }
    }

    func value(for control: DisplayControlKind) -> Double {
        switch control {
        case .brightness:
            brightness
        case .volume:
            volume
        case .contrast:
            contrast
        }
    }

    mutating func setValue(_ value: Double, for control: DisplayControlKind) {
        switch control {
        case .brightness:
            brightness = value
        case .volume:
            volume = value
        case .contrast:
            contrast = value
        }
    }

    mutating func setSupported(_ isSupported: Bool, for control: DisplayControlKind) {
        switch control {
        case .brightness:
            supportsBrightness = isSupported
        case .volume:
            supportsVolume = isSupported
        case .contrast:
            supportsContrast = isSupported
        }
    }
}

nonisolated(unsafe) private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
    guard let userInfo else { return }
    let controller = Unmanaged<DisplayControlController>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in
        controller.scheduleRefresh()
    }
}

nonisolated enum DisplayControlKind: Hashable {
    case brightness
    case volume
    case contrast

    var defaultValue: Double {
        switch self {
        case .brightness:
            50
        case .volume:
            40
        case .contrast:
            75
        }
    }

    var storageKey: String {
        switch self {
        case .brightness:
            "brightness"
        case .volume:
            "volume"
        case .contrast:
            "contrast"
        }
    }
}

private nonisolated struct ControlKey: Hashable {
    let displayID: CGDirectDisplayID
    let control: DisplayControlKind
}

final class DisplayControlService {
    private let displayServices = DisplayServicesBridge()
    private let ddc = DisplayDDCBridge()
    private let modeService = DisplayModeService()
    private let defaults = UserDefaults.standard

    func displays() -> [ControlledDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            AppLogger.ui.error("CGGetOnlineDisplayList failed")
            return []
        }

        let displayIDs = Array(ids.prefix(Int(count)))
        AppLogger.ui.info("Detected \(displayIDs.count) online displays")
        ddc.refresh(displayIDs: displayIDs)

        return displayIDs.map { id in
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let name = displayName(for: id, isBuiltIn: isBuiltIn)
            let storageID = displayStorageID(for: id, name: name, isBuiltIn: isBuiltIn)
            let appleBrightness = isBuiltIn ? displayServices.getBrightness(displayID: id) : nil
            let hasDDCService = !isBuiltIn && ddc.hasService(for: id)
            let ddcBrightness = isBuiltIn ? nil : ddc.read(.brightness, displayID: id)
            let ddcVolume = isBuiltIn ? nil : ddc.read(.volume, displayID: id)
            let ddcContrast = isBuiltIn ? nil : ddc.read(.contrast, displayID: id)
            let hidpiState = isBuiltIn
                ? DisplayHiDPIState(isSupported: false, isEnabled: false, modeDescription: nil, unavailableReason: "内建屏无需设置")
                : modeService.hidpiState(displayID: id)
            let storedBrightness = storedValue(for: .brightness, displayStorageID: storageID)
            let storedVolume = storedValue(for: .volume, displayStorageID: storageID)
            let storedContrast = storedValue(for: .contrast, displayStorageID: storageID)

            return ControlledDisplay(
                id: id,
                storageID: storageID,
                name: name,
                isBuiltIn: isBuiltIn,
                supportsBrightness: isBuiltIn ? appleBrightness != nil : (ddcBrightness != nil || storedBrightness != nil || hasDDCService),
                supportsVolume: !isBuiltIn && (ddcVolume != nil || storedVolume != nil),
                supportsContrast: !isBuiltIn && (ddcContrast != nil || storedContrast != nil),
                supportsHiDPI: hidpiState.isSupported,
                brightness: appleBrightness.map { Double($0 * 100) }
                    ?? ddcBrightness
                    ?? storedBrightness
                    ?? DisplayControlKind.brightness.defaultValue,
                volume: ddcVolume
                    ?? storedVolume
                    ?? DisplayControlKind.volume.defaultValue,
                contrast: ddcContrast
                    ?? storedContrast
                    ?? DisplayControlKind.contrast.defaultValue,
                hidpiEnabled: hidpiState.isEnabled,
                hidpiModeDescription: hidpiState.modeDescription,
                brightnessUnavailableReason: isBuiltIn ? "系统亮度服务不可用" : (hasDDCService ? nil : "未匹配到 DDC/CI 服务"),
                volumeUnavailableReason: isBuiltIn ? "内建屏不支持 DDC 音量" : (ddcVolume != nil || storedVolume != nil ? nil : "显示器未响应音量 VCP"),
                contrastUnavailableReason: isBuiltIn ? "内建屏不支持 DDC 对比度" : (ddcContrast != nil || storedContrast != nil ? nil : "显示器未响应对比度 VCP"),
                hidpiUnavailableReason: hidpiState.unavailableReason
            )
        }
    }

    func setValue(_ value: Double, for control: DisplayControlKind, display: ControlledDisplay) -> Bool {
        guard display.supports(control) else {
            return false
        }

        if display.isBuiltIn {
            switch control {
            case .brightness:
                return displayServices.setBrightness(displayID: display.id, value: Float(value / 100))
            case .volume, .contrast:
                return false
            }
        }

        let success = ddc.write(value, for: control, displayID: display.id)
        if success {
            saveStoredValue(value, for: control, displayStorageID: display.storageID)
        }
        return success
    }

    private func displayName(for id: CGDirectDisplayID, isBuiltIn: Bool) -> String {
        if isBuiltIn {
            return "视网膜显示器"
        }

        if let info = CoreDisplay_DisplayCreateInfoDictionary(id)?.takeRetainedValue() as? [String: Any],
           let localizedNames = info["DisplayProductName"] as? [String: String] {
            let name = localizedNames[Locale.current.identifier]
                ?? localizedNames["zh_CN"]
                ?? localizedNames["en_US"]
                ?? localizedNames.first?.value
            if let name {
                return name
            }
        }

        let model = CGDisplayModelNumber(id)
        return model == 0 ? "外接显示器" : "外接显示器 \(model)"
    }

    private func displayStorageID(for id: CGDirectDisplayID, name: String, isBuiltIn: Bool) -> String {
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        let role = isBuiltIn ? "builtIn" : "external"
        let sanitizedName = name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "\(role).\(sanitizedName).\(vendor).\(model).\(serial)"
    }

    private func storedValue(for control: DisplayControlKind, displayStorageID: String) -> Double? {
        let key = storedValueKey(for: control, displayStorageID: displayStorageID)
        guard defaults.object(forKey: key) != nil else {
            return nil
        }
        return min(100, max(0, defaults.double(forKey: key)))
    }

    private func saveStoredValue(_ value: Double, for control: DisplayControlKind, displayStorageID: String) {
        defaults.set(min(100, max(0, value)), forKey: storedValueKey(for: control, displayStorageID: displayStorageID))
    }

    private func storedValueKey(for control: DisplayControlKind, displayStorageID: String) -> String {
        "displayControl.value.\(displayStorageID).\(control.storageKey)"
    }
}

private final class DisplayModeService {
    private let overrideRoot = "/Library/Displays/Contents/Resources/Overrides"

    func hidpiState(displayID: CGDirectDisplayID) -> DisplayHiDPIState {
        guard displayID != 0 else {
            return DisplayHiDPIState(
                isSupported: false,
                isEnabled: false,
                modeDescription: nil,
                unavailableReason: "无法识别显示器"
            )
        }

        guard vendorID(displayID) > 0, productID(displayID) > 0 else {
            return DisplayHiDPIState(
                isSupported: false,
                isEnabled: false,
                modeDescription: nil,
                unavailableReason: "无法读取厂商/产品 ID"
            )
        }

        let isInstalled = FileManager.default.fileExists(atPath: overrideFilePath(displayID: displayID))
        return DisplayHiDPIState(
            isSupported: true,
            isEnabled: isInstalled,
            modeDescription: isInstalled ? "已安装配置" : "安装配置",
            unavailableReason: nil
        )
    }

    func setHiDPIEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool {
        guard vendorID(displayID) > 0, productID(displayID) > 0 else {
            return false
        }

        let script = enabled ? installScript(displayID: displayID) : removeScript(displayID: displayID)
        return runAdministratorScript(script)
    }

    private func vendorID(_ displayID: CGDirectDisplayID) -> UInt32 {
        CGDisplayVendorNumber(displayID)
    }

    private func productID(_ displayID: CGDirectDisplayID) -> UInt32 {
        CGDisplayModelNumber(displayID)
    }

    private func vendorHex(_ displayID: CGDirectDisplayID) -> String {
        String(format: "%x", vendorID(displayID))
    }

    private func productHex(_ displayID: CGDirectDisplayID) -> String {
        String(format: "%x", productID(displayID))
    }

    private func overrideDirectory(displayID: CGDirectDisplayID) -> String {
        "\(overrideRoot)/DisplayVendorID-\(vendorHex(displayID))"
    }

    private func overrideFilePath(displayID: CGDirectDisplayID) -> String {
        "\(overrideDirectory(displayID: displayID))/DisplayProductID-\(productHex(displayID))"
    }

    private func installScript(displayID: CGDirectDisplayID) -> String {
        let vendor = vendorID(displayID)
        let product = productID(displayID)
        let directory = shellQuote(overrideDirectory(displayID: displayID))
        let file = shellQuote(overrideFilePath(displayID: displayID))
        let resolutionList = hidpiResolutions(displayID: displayID)
            .map { "\($0.width)x\($0.height)" }
            .joined(separator: " ")

        return """
        set -e
        mkdir -p \(directory)
        tmpfile="$(mktemp /tmp/fanshu-hidpi.XXXXXX)"
        cat > "$tmpfile" <<'PLIST_HEAD'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DisplayProductID</key>
            <integer>\(product)</integer>
            <key>DisplayVendorID</key>
            <integer>\(vendor)</integer>
            <key>scale-resolutions</key>
            <array>
        PLIST_HEAD
        for res in \(resolutionList); do
            width="${res%x*}"
            height="${res#*x}"
            hidpi="$(printf '%08x %08x' "$((width * 2))" "$((height * 2))" | xxd -r -p | base64)"
            prefix="${hidpi:0:11}"
            printf '        <data>%sA</data>\\n' "$prefix" >> "$tmpfile"
            printf '        <data>%sAAAAB</data>\\n' "$prefix" >> "$tmpfile"
            printf '        <data>%sAAAABACAAAA==</data>\\n' "$prefix" >> "$tmpfile"
            printf '        <data>%sAAAAJAKAAAA==</data>\\n' "$prefix" >> "$tmpfile"
        done
        cat >> "$tmpfile" <<'PLIST_TAIL'
            </array>
            <key>target-default-ppmm</key>
            <real>10.0699301</real>
        </dict>
        </plist>
        PLIST_TAIL
        plutil -lint "$tmpfile" >/dev/null
        install -o root -g wheel -m 0644 "$tmpfile" \(file)
        rm -f "$tmpfile"
        defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool YES
        """
    }

    private func removeScript(displayID: CGDirectDisplayID) -> String {
        let file = shellQuote(overrideFilePath(displayID: displayID))
        return """
        set -e
        rm -f \(file)
        defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool YES
        """
    }

    private func runAdministratorScript(_ script: String) -> Bool {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fanshu-hidpi-\(UUID().uuidString).sh")

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            AppLogger.ui.error("Failed to prepare HiDPI script: \(error.localizedDescription, privacy: .public)")
            return false
        }
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"/bin/bash \" & quoted form of \(appleScriptString(scriptURL.path)) with administrator privileges"
        ]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            AppLogger.ui.error("HiDPI administrator script failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func hidpiResolutions(displayID: CGDirectDisplayID) -> [(width: Int, height: Int)] {
        let width = Int(CGDisplayPixelsWide(displayID))
        let height = Int(CGDisplayPixelsHigh(displayID))
        let aspect = Double(width) / Double(max(height, 1))

        let presets: [(Int, Int)]
        if abs(aspect - (16.0 / 9.0)) < 0.04 {
            presets = [
                (width, height),
                scaled(width, height, 0.8),
                scaled(width, height, 0.75),
                scaled(width, height, 2.0 / 3.0),
                scaled(width, height, 0.5),
                (1920, 1080),
                (1680, 945),
                (1440, 810),
                (1280, 720)
            ]
        } else if abs(aspect - (21.0 / 9.0)) < 0.18 {
            presets = [
                (width, height),
                scaled(width, height, 0.8),
                scaled(width, height, 0.75),
                scaled(width, height, 2.0 / 3.0),
                scaled(width, height, 0.5),
                (2752, 1152),
                (2580, 1080),
                (2365, 990),
                (1720, 720)
            ]
        } else if abs(aspect - (16.0 / 10.0)) < 0.06 {
            presets = [
                (width, height),
                scaled(width, height, 0.8),
                scaled(width, height, 0.75),
                scaled(width, height, 2.0 / 3.0),
                scaled(width, height, 0.5),
                (1680, 1050),
                (1440, 900),
                (1280, 800)
            ]
        } else {
            presets = [
                (width, height),
                scaled(width, height, 0.8),
                scaled(width, height, 0.75),
                scaled(width, height, 2.0 / 3.0),
                scaled(width, height, 0.5)
            ]
        }

        var seen = Set<String>()
        return presets.filter { item in
            guard item.0 >= 320, item.1 >= 180 else { return false }
            let ratio = Double(item.0) / Double(max(item.1, 1))
            guard abs(ratio - aspect) < 0.08 else { return false }
            let key = "\(item.0)x\(item.1)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func scaled(_ width: Int, _ height: Int, _ factor: Double) -> (Int, Int) {
        (Int((Double(width) * factor).rounded()), Int((Double(height) * factor).rounded()))
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

private struct DisplayHiDPIState {
    let isSupported: Bool
    let isEnabled: Bool
    let modeDescription: String?
    let unavailableReason: String?
}

private final class DisplayServicesBridge {
    func getBrightness(displayID: CGDirectDisplayID) -> Float? {
        var value: Float = -1
        let result = DisplayServicesGetBrightness(displayID, &value)
        guard result == 0, value >= 0 else {
            return nil
        }
        return min(1, max(0, value))
    }

    func setBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        let clampedValue = min(1, max(0, value))
        return DisplayServicesSetBrightness(displayID, clampedValue) == 0
    }
}
