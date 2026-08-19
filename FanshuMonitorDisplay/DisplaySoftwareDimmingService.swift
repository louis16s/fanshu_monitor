import AppKit
import CoreGraphics
import Foundation

nonisolated enum DisplayDimmingCalibration {
    static let hardwareZeroUserBrightness: Double = 15
    static let maximumOverlayOpacity: Double = 0.70

    static func hardwareBrightness(forUserBrightness userBrightness: Double) -> Double {
        let clamped = min(100, max(0, userBrightness))
        guard clamped > hardwareZeroUserBrightness else { return 0 }
        return min(
            100,
            max(0, (clamped - hardwareZeroUserBrightness) / (100 - hardwareZeroUserBrightness) * 100)
        )
    }

    static func overlayOpacity(forUserBrightness userBrightness: Double) -> Double {
        let clamped = min(hardwareZeroUserBrightness, max(0, userBrightness))
        return (1 - clamped / hardwareZeroUserBrightness) * maximumOverlayOpacity
    }
}

enum DisplaySoftwareDimmingWindowPolicy {
    // A later-created screen saver window can cover windows at the same level.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
}

nonisolated final class DisplaySoftwareDimmingService: @unchecked Sendable {
    private let dimmingThreshold: Double = DisplayDimmingCalibration.hardwareZeroUserBrightness
    private let maximumOverlayOpacity: Double = DisplayDimmingCalibration.maximumOverlayOpacity
    private let lock = NSLock()
    private var requestedBrightness: [CGDirectDisplayID: Double] = [:]
    private var quantizationOverlayOpacity: [CGDirectDisplayID: Double] = [:]
    @MainActor private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]

    func userBrightness(
        for displayID: CGDirectDisplayID,
        storedUserBrightness: Double?,
        hardwareBrightness: Double?,
        restoredQuantizationOpacity: Double
    ) -> Double? {
        if let cached = cachedBrightness(for: displayID) {
            return cached
        }

        if let storedUserBrightness {
            setUserBrightness(
                storedUserBrightness,
                for: displayID,
                additionalOverlayOpacity: restoredQuantizationOpacity
            )
            return storedUserBrightness
        }

        guard let hardwareBrightness else { return nil }
        return min(100, max(0, dimmingThreshold + (hardwareBrightness / 100) * (100 - dimmingThreshold)))
    }

    func hardwareBrightness(forUserBrightness userBrightness: Double) -> Double {
        DisplayDimmingCalibration.hardwareBrightness(forUserBrightness: userBrightness)
    }

    func setUserBrightness(
        _ userBrightness: Double,
        for displayID: CGDirectDisplayID,
        additionalOverlayOpacity: Double = 0
    ) {
        let clamped = min(100, max(0, userBrightness))
        let clampedAdditionalOpacity = min(1, max(0, additionalOverlayOpacity))
        lock.lock()
        requestedBrightness[displayID] = clamped
        quantizationOverlayOpacity[displayID] = clampedAdditionalOpacity
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.apply(
                userBrightness: clamped,
                additionalOverlayOpacity: clampedAdditionalOpacity,
                for: displayID
            )
        }
    }

    func sync(with displays: [ControlledDisplay]) {
        let displayIDs = Set(displays.map(\.id))
        let brightnessByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.brightness) })

        lock.lock()
        requestedBrightness = requestedBrightness.filter { displayIDs.contains($0.key) }
        quantizationOverlayOpacity = quantizationOverlayOpacity.filter { displayIDs.contains($0.key) }
        for (displayID, brightness) in brightnessByID where CGDisplayIsBuiltin(displayID) == 0 {
            requestedBrightness[displayID] = brightness
        }
        let values = requestedBrightness
        let additionalOpacities = quantizationOverlayOpacity
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            for (displayID, brightness) in values {
                self.apply(
                    userBrightness: brightness,
                    additionalOverlayOpacity: additionalOpacities[displayID] ?? 0,
                    for: displayID
                )
            }
            self.removeMissingWindows(keeping: displayIDs)
        }
    }

    func clear(displayID: CGDirectDisplayID) {
        lock.lock()
        requestedBrightness[displayID] = nil
        quantizationOverlayOpacity[displayID] = nil
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.removeWindow(for: displayID)
        }
    }

    func clearAll() {
        lock.lock()
        requestedBrightness.removeAll()
        quantizationOverlayOpacity.removeAll()
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
    private func apply(
        userBrightness: Double,
        additionalOverlayOpacity: Double,
        for displayID: CGDirectDisplayID
    ) {
        guard CGDisplayIsBuiltin(displayID) == 0 else {
            removeWindow(for: displayID)
            return
        }

        let baseOpacity = overlayOpacity(for: userBrightness)
        let opacity = 1 - (1 - baseOpacity) * (1 - additionalOverlayOpacity)
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
        DisplayDimmingCalibration.overlayOpacity(forUserBrightness: userBrightness)
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
        window.level = DisplaySoftwareDimmingWindowPolicy.level
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
