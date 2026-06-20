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

@MainActor
final class DisplayControlController: ObservableObject {
    @Published private(set) var displays: [ControlledDisplay] = []
    @Published private var builtInBlackoutDisplayIDs: Set<CGDirectDisplayID> = []
    @Published private var pendingValues: [CGDirectDisplayID: [DisplayControlKind: Double]] = [:]

    private let service = DisplayControlService()
    private let worker = DisplayControlWorker()
    private var fallbackValues: [CGDirectDisplayID: [DisplayControlKind: Double]] = [:]
    private var recentWrittenValues: [ControlKey: RecentDisplayValue] = [:]
    private var screenChangeObserver: NSObjectProtocol?
    private var refreshWorkItem: DispatchWorkItem?
    private var displayCallbackRegistered = false
    weak var settings: MonitorSettings? {
        didSet {
            service.softwareDimmingEnabled = settings?.displaySoftwareDimmingEnabled ?? true
            if service.softwareDimmingEnabled {
                syncSoftwareDimming()
            } else {
                service.clearSoftwareDimming()
            }
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
        Task { @MainActor [service] in
            service.clearBuiltInBlackouts()
            service.clearSoftwareDimming()
        }
    }

    func refreshAsync() {
        worker.refresh(service: service) { detectedDisplays in
            DispatchQueue.main.async {
                AppLogger.ui.info("Display refresh completed, found \(detectedDisplays.count) displays")
                let mergedDisplays = detectedDisplays.map { self.mergedDisplayValues(for: $0) }
                self.displays = mergedDisplays
                for display in mergedDisplays {
                    self.seedFallbackValues(for: display)
                }
                self.syncBuiltInBlackouts()
                self.syncSoftwareDimming()
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
        let mergedDisplays = detectedDisplays.map { mergedDisplayValues(for: $0) }
        displays = mergedDisplays
        for display in mergedDisplays {
            seedFallbackValues(for: display)
        }
        syncBuiltInBlackouts()
        syncSoftwareDimming()
    }

    func isBuiltInBlackoutEnabled(displayID: CGDirectDisplayID) -> Bool {
        builtInBlackoutDisplayIDs.contains(displayID)
    }

    func toggleBuiltInBlackout(displayID: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == displayID }),
              display.isBuiltIn
        else {
            return
        }

        let shouldEnable = !builtInBlackoutDisplayIDs.contains(displayID)
        if service.setBuiltInBlackout(shouldEnable, display: display, displays: displays) {
            if shouldEnable {
                builtInBlackoutDisplayIDs.insert(displayID)
            } else {
                builtInBlackoutDisplayIDs.remove(displayID)
            }
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

    func stopAutomaticRefresh() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
            displayCallbackRegistered = false
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
        guard let displayID = primaryDisplayIDUnderMouse() ?? displayIDsUnderMouse().first else { return nil }
        if displays.isEmpty {
            refreshNow()
        }
        return displays.first { $0.id == displayID }
    }

    func brightnessDisplayUnderMouse() -> ControlledDisplay? {
        if let primaryDisplayID = primaryDisplayIDUnderMouse() {
            if displays.isEmpty {
                AppLogger.ui.debug("Brightness key target list is empty; scheduling display refresh")
                refreshNow()
                return nil
            }

            guard let primaryDisplay = displays.first(where: { $0.id == primaryDisplayID }) else {
                AppLogger.ui.debug("Brightness key primary display \(primaryDisplayID) is not in controller list; scheduling display refresh")
                refreshNow()
                return nil
            }

            if primaryDisplay.isBuiltIn {
                AppLogger.ui.debug("Brightness key pass-through: mouse is on built-in display \(primaryDisplayID)")
                return nil
            }

            if primaryDisplay.supports(.brightness) {
                return primaryDisplay
            }

            AppLogger.ui.debug(
                "Brightness key pass-through: primary external display \(primaryDisplayID) does not support brightness, reason: \(primaryDisplay.brightnessUnavailableReason ?? "unknown", privacy: .public)"
            )
            return nil
        }

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

    private func primaryDisplayIDUnderMouse() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) else {
            return nil
        }
        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
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

        if let displayID = primaryDisplayIDUnderMouse() {
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
        service.softwareDimmingEnabled = settings?.displaySoftwareDimmingEnabled ?? true
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

    private func seedFallbackValues(for display: ControlledDisplay) {
        fallbackValues[display.id] = [
            .brightness: display.brightness,
            .volume: display.volume,
            .contrast: display.contrast
        ]
    }

    private func mergedDisplayValues(for display: ControlledDisplay) -> ControlledDisplay {
        pruneExpiredRecentValues()
        var mergedDisplay = display
        for control in DisplayControlKind.allCases {
            let key = ControlKey(displayID: display.id, control: control)
            if let pendingValue = pendingValues[display.id]?[control] {
                mergedDisplay.setValue(pendingValue, for: control)
            } else if let recentValue = recentWrittenValues[key] {
                mergedDisplay.setValue(recentValue.value, for: control)
            }
        }
        return mergedDisplay
    }

    private func pruneExpiredRecentValues() {
        let now = Date()
        recentWrittenValues = recentWrittenValues.filter { now.timeIntervalSince($0.value.date) < 3 }
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

        if result.success, isCurrentResult {
            updateLocalValue(result.value, for: result.key.control, displayID: result.key.displayID)
            fallbackValues[result.key.displayID, default: [:]][result.key.control] = result.value
            recentWrittenValues[result.key] = RecentDisplayValue(value: result.value, date: Date())
            AppLogger.ui.debug("Write succeeded for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public)")
        } else if result.success {
            AppLogger.ui.debug("Ignored stale write result for display \(result.key.displayID), control: \(result.key.control.storageKey, privacy: .public)")
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

    private func syncSoftwareDimming() {
        service.softwareDimmingEnabled = settings?.displaySoftwareDimmingEnabled ?? true
        guard service.softwareDimmingEnabled else {
            service.clearSoftwareDimming()
            return
        }
        service.syncSoftwareDimming(for: displays)
    }

    private func syncBuiltInBlackouts() {
        let displayIDs = Set(displays.map(\.id))
        builtInBlackoutDisplayIDs = builtInBlackoutDisplayIDs.intersection(displayIDs)
        guard displays.contains(where: { !$0.isBuiltIn }) else {
            builtInBlackoutDisplayIDs.removeAll()
            service.clearBuiltInBlackouts()
            return
        }
        service.syncBuiltInBlackouts(keeping: builtInBlackoutDisplayIDs, displays: displays)
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
    var brightness: Double
    var volume: Double
    var contrast: Double
    var brightnessUnavailableReason: String?
    var volumeUnavailableReason: String?
    var contrastUnavailableReason: String?

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

nonisolated enum DisplayControlKind: Hashable, CaseIterable {
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

private struct RecentDisplayValue {
    let value: Double
    let date: Date
}

final class DisplayControlService {
    private let displayServices = DisplayServicesBridge()
    private let ddc = DisplayDDCBridge()
    private let defaults = UserDefaults.standard
    private let softwareDimming = DisplaySoftwareDimmingService()
    private let builtInBlackout = BuiltInDisplayBlackoutService()
    var softwareDimmingEnabled = true

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
                brightness: appleBrightness.map { Double($0 * 100) }
                    ?? softwareDimming.userBrightness(for: id, storedUserBrightness: storedBrightness, hardwareBrightness: ddcBrightness)
                    ?? storedBrightness
                    ?? DisplayControlKind.brightness.defaultValue,
                volume: ddcVolume
                    ?? storedVolume
                    ?? DisplayControlKind.volume.defaultValue,
                contrast: ddcContrast
                    ?? storedContrast
                    ?? DisplayControlKind.contrast.defaultValue,
                brightnessUnavailableReason: isBuiltIn ? "系统亮度服务不可用" : (hasDDCService ? nil : "未匹配到 DDC/CI 服务"),
                volumeUnavailableReason: isBuiltIn ? "内建屏不支持 DDC 音量" : (ddcVolume != nil || storedVolume != nil ? nil : "显示器未响应音量 VCP"),
                contrastUnavailableReason: isBuiltIn ? "内建屏不支持 DDC 对比度" : (ddcContrast != nil || storedContrast != nil ? nil : "显示器未响应对比度 VCP")
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

        var writeValue = value
        if control == .brightness {
            if softwareDimmingEnabled {
                writeValue = softwareDimming.hardwareBrightness(forUserBrightness: value)
            } else {
                softwareDimming.clear(displayID: display.id)
            }
        }

        let success = ddc.write(writeValue, for: control, displayID: display.id)
        if success {
            if control == .brightness, softwareDimmingEnabled {
                softwareDimming.setUserBrightness(value, for: display.id)
            }
            saveStoredValue(value, for: control, displayStorageID: display.storageID)
        }
        return success
    }

    func syncSoftwareDimming(for displays: [ControlledDisplay]) {
        softwareDimming.sync(with: displays)
    }

    func clearSoftwareDimming() {
        softwareDimming.clearAll()
    }

    func setBuiltInBlackout(_ enabled: Bool, display: ControlledDisplay, displays: [ControlledDisplay]) -> Bool {
        guard display.isBuiltIn else {
            return false
        }

        if enabled {
            guard let mirrorTarget = displays.first(where: { !$0.isBuiltIn }) else {
                return false
            }
            let previousBrightness = displayServices.getBrightness(displayID: display.id)
                ?? Float(display.brightness / 100)
            let didMirror = builtInBlackout.setEnabled(
                true,
                displayID: display.id,
                mirrorTargetID: mirrorTarget.id,
                previousBrightness: previousBrightness
            )
            guard didMirror else {
                return false
            }
            _ = displayServices.setBrightness(displayID: display.id, value: 0)
            return didMirror
        }

        guard builtInBlackout.setEnabled(false, displayID: display.id, mirrorTargetID: nil, previousBrightness: nil) else {
            return false
        }
        let restoredBrightness = builtInBlackout.restoreBrightness(for: display.id) ?? Float(display.brightness / 100)
        _ = displayServices.setBrightness(displayID: display.id, value: restoredBrightness)
        return true
    }

    func syncBuiltInBlackouts(keeping displayIDs: Set<CGDirectDisplayID>, displays: [ControlledDisplay]) {
        builtInBlackout.sync(keeping: displayIDs)
        guard let mirrorTarget = displays.first(where: { !$0.isBuiltIn })?.id else { return }
        for displayID in displayIDs {
            _ = builtInBlackout.setEnabled(true, displayID: displayID, mirrorTargetID: mirrorTarget, previousBrightness: nil)
        }
    }

    func clearBuiltInBlackouts() {
        let brightnessByDisplayID = builtInBlackout.clearAll()
        for (displayID, brightness) in brightnessByDisplayID {
            _ = displayServices.setBrightness(displayID: displayID, value: brightness)
        }
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

private enum DisplayDimmingCalibration {
    static let hardwareZeroUserBrightness: Double = 15
    static let maximumOverlayOpacity: Double = 0.65
}

private final class DisplaySoftwareDimmingService {
    private let dimmingThreshold: Double = DisplayDimmingCalibration.hardwareZeroUserBrightness
    private let maximumOverlayOpacity: Double = DisplayDimmingCalibration.maximumOverlayOpacity
    private let lock = NSLock()
    private var requestedBrightness: [CGDirectDisplayID: Double] = [:]
    @MainActor private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]

    func userBrightness(
        for displayID: CGDirectDisplayID,
        storedUserBrightness: Double?,
        hardwareBrightness: Double?
    ) -> Double? {
        if let cached = cachedBrightness(for: displayID) {
            return cached
        }

        if let storedUserBrightness, storedUserBrightness < dimmingThreshold {
            setUserBrightness(storedUserBrightness, for: displayID)
            return storedUserBrightness
        }

        guard let hardwareBrightness else { return nil }
        return min(100, max(0, dimmingThreshold + (hardwareBrightness / 100) * (100 - dimmingThreshold)))
    }

    func hardwareBrightness(forUserBrightness userBrightness: Double) -> Double {
        let clamped = min(100, max(0, userBrightness))
        guard clamped > dimmingThreshold else { return 0 }
        return min(100, max(0, (clamped - dimmingThreshold) / (100 - dimmingThreshold) * 100))
    }

    func setUserBrightness(_ userBrightness: Double, for displayID: CGDirectDisplayID) {
        let clamped = min(100, max(0, userBrightness))
        lock.lock()
        requestedBrightness[displayID] = clamped
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.apply(userBrightness: clamped, for: displayID)
        }
    }

    func sync(with displays: [ControlledDisplay]) {
        let displayIDs = Set(displays.map(\.id))
        let brightnessByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.brightness) })

        lock.lock()
        requestedBrightness = requestedBrightness.filter { displayIDs.contains($0.key) }
        for (displayID, brightness) in brightnessByID where CGDisplayIsBuiltin(displayID) == 0 {
            requestedBrightness[displayID] = brightness
        }
        let values = requestedBrightness
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for (displayID, brightness) in values {
                self.apply(userBrightness: brightness, for: displayID)
            }
            self.removeMissingWindows(keeping: displayIDs)
        }
    }

    func clear(displayID: CGDirectDisplayID) {
        lock.lock()
        requestedBrightness[displayID] = nil
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.removeWindow(for: displayID)
        }
    }

    func clearAll() {
        lock.lock()
        requestedBrightness.removeAll()
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for displayID in Array(self.overlayWindows.keys) {
                self.removeWindow(for: displayID)
            }
        }
    }

    private func cachedBrightness(for displayID: CGDirectDisplayID) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return requestedBrightness[displayID]
    }

    @MainActor
    private func apply(userBrightness: Double, for displayID: CGDirectDisplayID) {
        guard CGDisplayIsBuiltin(displayID) == 0 else {
            removeWindow(for: displayID)
            return
        }

        let opacity = overlayOpacity(for: userBrightness)
        guard opacity > 0.001 else {
            removeWindow(for: displayID)
            return
        }

        guard let screen = screen(for: displayID) else {
            removeWindow(for: displayID)
            return
        }

        let window = overlayWindows[displayID] ?? makeWindow(for: screen)
        overlayWindows[displayID] = window
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
        window.alphaValue = opacity
        window.orderFrontRegardless()
    }

    private func overlayOpacity(for userBrightness: Double) -> Double {
        let clamped = min(dimmingThreshold, max(0, userBrightness))
        return (1 - clamped / dimmingThreshold) * maximumOverlayOpacity
    }

    @MainActor
    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = NSView(frame: screen.frame)
        return window
    }

    @MainActor
    private func removeMissingWindows(keeping displayIDs: Set<CGDirectDisplayID>) {
        for displayID in Array(overlayWindows.keys) where !displayIDs.contains(displayID) {
            removeWindow(for: displayID)
        }
    }

    @MainActor
    private func removeWindow(for displayID: CGDirectDisplayID) {
        guard let window = overlayWindows[displayID] else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    @MainActor
    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

private final class BuiltInDisplayBlackoutService {
    private var previousBrightnessByDisplayID: [CGDirectDisplayID: Float] = [:]

    func setEnabled(
        _ enabled: Bool,
        displayID: CGDirectDisplayID,
        mirrorTargetID: CGDirectDisplayID?,
        previousBrightness: Float?
    ) -> Bool {
        guard CGDisplayIsBuiltin(displayID) != 0 else { return false }

        if enabled {
            guard let mirrorTargetID else { return false }
            let didConfigure = configureMirroring(displayID: displayID, mirrorTargetID: mirrorTargetID)
            if didConfigure, previousBrightnessByDisplayID[displayID] == nil {
                previousBrightnessByDisplayID[displayID] = previousBrightness
            }
            return didConfigure
        }

        return configureMirroring(displayID: displayID, mirrorTargetID: nil)
    }

    func restoreBrightness(for displayID: CGDirectDisplayID) -> Float? {
        previousBrightnessByDisplayID.removeValue(forKey: displayID)
    }

    func sync(keeping displayIDs: Set<CGDirectDisplayID>) {
        let removedIDs = Set(previousBrightnessByDisplayID.keys).subtracting(displayIDs)
        for displayID in removedIDs {
            _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
        }
        previousBrightnessByDisplayID = previousBrightnessByDisplayID.filter { displayIDs.contains($0.key) }
    }

    func clearAll() -> [CGDirectDisplayID: Float] {
        let brightnessByDisplayID = previousBrightnessByDisplayID
        previousBrightnessByDisplayID.removeAll()
        for displayID in brightnessByDisplayID.keys {
            _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
        }

        return brightnessByDisplayID
    }

    private func configureMirroring(displayID: CGDirectDisplayID, mirrorTargetID: CGDirectDisplayID?) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return false
        }

        let target = mirrorTargetID ?? kCGNullDirectDisplay
        CGConfigureDisplayMirrorOfDisplay(config, displayID, target)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result != .success {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return true
    }
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
