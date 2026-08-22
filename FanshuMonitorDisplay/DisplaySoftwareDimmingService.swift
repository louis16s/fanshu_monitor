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

    static func gammaFactor(
        forUserBrightness userBrightness: Double,
        additionalOverlayOpacity: Double = 0
    ) -> Double {
        let baseFactor = 1 - overlayOpacity(forUserBrightness: userBrightness)
        let quantizationFactor = 1 - min(1, max(0, additionalOverlayOpacity))
        return min(1, max(0, baseFactor * quantizationFactor))
    }
}

enum DisplaySoftwareDimmingWindowPolicy {
    // A later-created screen saver window can cover windows at the same level.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let sharingType: NSWindow.SharingType = .none
}

nonisolated final class DisplaySoftwareDimmingService: @unchecked Sendable {
    private struct ApplyToken: Sendable {
        let lifecycleGeneration: UInt64
        let requestGeneration: UInt64
    }

    private let dimmingThreshold: Double = DisplayDimmingCalibration.hardwareZeroUserBrightness
    private let maximumOverlayOpacity: Double = DisplayDimmingCalibration.maximumOverlayOpacity
    private let lock = NSLock()
    private let gamma = DisplayGammaService()
    private var requestedBrightness: [CGDirectDisplayID: Double] = [:]
    private var quantizationOverlayOpacity: [CGDirectDisplayID: Double] = [:]
    private var requestGenerations: [CGDirectDisplayID: UInt64] = [:]
    private var lifecycleGeneration: UInt64 = 0
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
        let token = nextApplyTokenLocked(for: displayID)
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(token, for: displayID) else { return }
            self.apply(
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
        requestGenerations = requestGenerations.filter { displayIDs.contains($0.key) }
        for (displayID, brightness) in brightnessByID where CGDisplayIsBuiltin(displayID) == 0 {
            requestedBrightness[displayID] = brightness
        }
        let values = requestedBrightness
        let additionalOpacities = quantizationOverlayOpacity
        let requests = values.map { displayID, brightness in
            (
                displayID: displayID,
                brightness: brightness,
                opacity: additionalOpacities[displayID] ?? 0,
                token: nextApplyTokenLocked(for: displayID)
            )
        }
        let syncLifecycleGeneration = lifecycleGeneration
        lock.unlock()

        gamma.removeMissingDisplays(
            keeping: Set(values.keys.filter { CGDisplayIsBuiltin($0) == 0 })
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            for request in requests where self.isCurrent(request.token, for: request.displayID) {
                self.apply(
                    userBrightness: request.brightness,
                    additionalOverlayOpacity: request.opacity,
                    for: request.displayID
                )
            }
            if self.isCurrent(lifecycleGeneration: syncLifecycleGeneration) {
                self.removeMissingWindows(keeping: displayIDs)
            }
        }
    }

    func clear(displayID: CGDirectDisplayID) {
        lock.lock()
        requestedBrightness[displayID] = nil
        quantizationOverlayOpacity[displayID] = nil
        requestGenerations[displayID, default: 0] &+= 1
        lock.unlock()

        _ = gamma.restore(displayID: displayID)

        Task { @MainActor [weak self] in
            self?.removeWindow(for: displayID)
        }
    }

    func clearAll() {
        lock.lock()
        lifecycleGeneration &+= 1
        requestedBrightness.removeAll()
        quantizationOverlayOpacity.removeAll()
        requestGenerations.removeAll()
        lock.unlock()

        gamma.restoreAll()

        removeAllWindows()
    }

    /// Restores the system color pipeline before display sleep while retaining
    /// the requested brightness values for the first topology refresh after wake.
    func suspendForDisplaySleep() {
        lock.lock()
        lifecycleGeneration &+= 1
        lock.unlock()

        gamma.restoreAll()
        removeAllWindows()
    }

    private func removeAllWindows() {
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

    private func nextApplyTokenLocked(for displayID: CGDirectDisplayID) -> ApplyToken {
        requestGenerations[displayID, default: 0] &+= 1
        return ApplyToken(
            lifecycleGeneration: lifecycleGeneration,
            requestGeneration: requestGenerations[displayID] ?? 0
        )
    }

    private func isCurrent(_ token: ApplyToken, for displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token.lifecycleGeneration == lifecycleGeneration
            && token.requestGeneration == requestGenerations[displayID]
    }

    private func isCurrent(lifecycleGeneration expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return expected == lifecycleGeneration
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

        let gammaFactor = DisplayDimmingCalibration.gammaFactor(
            forUserBrightness: userBrightness,
            additionalOverlayOpacity: additionalOverlayOpacity
        )
        if gamma.apply(factor: gammaFactor, displayID: displayID) {
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
        window.sharingType = DisplaySoftwareDimmingWindowPolicy.sharingType
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
