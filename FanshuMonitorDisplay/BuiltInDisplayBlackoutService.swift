import CoreGraphics
import Darwin
import Foundation
import OSLog

nonisolated final class BuiltInDisplayBlackoutService: @unchecked Sendable {
    private enum IsolationMode {
        case disconnected
        case mirrored
    }

    private struct IsolationState {
        var previousBrightness: Float?
        var mode: IsolationMode
        var isPersistent: Bool
    }

    private typealias ConfigureDisplayEnabledFunction = @convention(c) (
        CGDisplayConfigRef?,
        CGDirectDisplayID,
        Bool
    ) -> CGError

    private typealias GetDisplayListFunction = @convention(c) (
        UInt32,
        UnsafeMutablePointer<CGDirectDisplayID>?,
        UnsafeMutablePointer<UInt32>?
    ) -> CGError

    private let frameworkHandles: [UnsafeMutableRawPointer]
    private let configureDisplayEnabled: ConfigureDisplayEnabledFunction?
    private let getDisplayList: GetDisplayListFunction?
    private let stateLock = NSLock()
    private var states: [CGDirectDisplayID: IsolationState] = [:]

    init() {
        let frameworkPaths: [String] = [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        ]
        frameworkHandles = frameworkPaths.compactMap { path in
            path.withCString { dlopen($0, RTLD_LAZY | RTLD_LOCAL) }
        }
        configureDisplayEnabled = Self.resolveConfigureDisplayEnabled(
            handles: frameworkHandles
        )
        if configureDisplayEnabled == nil {
            SystemCapabilityRegistry.shared.reportUnavailable(
                .displayIsolation,
                reason: "display isolation symbol unavailable"
            )
        } else {
            SystemCapabilityRegistry.shared.reportAvailable(.displayIsolation)
        }
        getDisplayList = Self.resolveSymbol(
            handles: frameworkHandles,
            names: ["CGSGetDisplayList", "SLSGetDisplayList"],
            as: GetDisplayListFunction.self
        )
    }

    private static func resolveConfigureDisplayEnabled(
        handles: [UnsafeMutableRawPointer]
    ) -> ConfigureDisplayEnabledFunction? {
        for symbolName in ["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"] {
            if let function = resolveSymbol(
                handles: handles,
                names: [symbolName],
                as: ConfigureDisplayEnabledFunction.self
            ) {
                AppLogger.ui.notice("Using display isolation API: \(symbolName, privacy: .public)")
                return function
            }
        }
        AppLogger.ui.error("Display isolation API is unavailable; using mirror fallback")
        return nil
    }

    private static func resolveSymbol<Function>(
        handles: [UnsafeMutableRawPointer],
        names: [String],
        as type: Function.Type
    ) -> Function? {
        for handle in handles {
            for name in names {
                if let symbol = dlsym(handle, name) {
                    return unsafeBitCast(symbol, to: type)
                }
            }
        }
        return nil
    }

    func setEnabled(
        _ enabled: Bool,
        displayID: CGDirectDisplayID,
        mirrorTargetID: CGDirectDisplayID?,
        previousBrightness: Float?
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if enabled {
            guard let mirrorTargetID else { return false }
            guard CGDisplayIsBuiltin(displayID) == 1 || states[displayID] != nil else {
                return false
            }

            let displayIsAlreadyIsolated = !onlineDisplayIDs().contains(displayID)
                || CGDisplayIsActive(displayID) == 0
            if displayIsAlreadyIsolated {
                states[displayID] = IsolationState(
                    previousBrightness: states[displayID]?.previousBrightness ?? previousBrightness,
                    mode: .disconnected,
                    isPersistent: true
                )
                return true
            }

            _ = configureDisplay(
                displayID: displayID,
                enabled: false,
                completionOption: BuiltInDisplayConfigurationPolicy.isolationOption
            )
            if waitForTargetState(displayID: displayID, blackoutEnabled: true) {
                states[displayID] = IsolationState(
                    previousBrightness: states[displayID]?.previousBrightness ?? previousBrightness,
                    mode: .disconnected,
                    isPersistent: true
                )
                return true
            }

            let didMirror = configureMirroring(displayID: displayID, mirrorTargetID: mirrorTargetID)
            if didMirror {
                states[displayID] = IsolationState(
                    previousBrightness: states[displayID]?.previousBrightness ?? previousBrightness,
                    mode: .mirrored,
                    isPersistent: false
                )
            }
            return didMirror
        }

        // Topology callbacks and the recovery watchdog can race with
        // WindowServer's own restoration. Never submit another private display
        // configuration after the panel is online and unmirrored, including
        // while it is asleep; that request can wait indefinitely for a previous
        // commit on some systems.
        if isDisplayRestored(displayID) {
            states.removeValue(forKey: displayID)
            return true
        }

        guard let state = states[displayID] else {
            // A restart loses the in-memory isolation mode. Clear either
            // possible fallback, enable the display, then verify the topology.
            _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
            _ = restoreDisconnectedDisplay(displayID: displayID)
            return waitForTargetState(displayID: displayID, blackoutEnabled: false)
        }
        switch state.mode {
        case .disconnected:
            _ = restoreDisconnectedDisplay(displayID: displayID)
        case .mirrored:
            _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
        }
        return waitForTargetState(displayID: displayID, blackoutEnabled: false)
    }

    func restoreBrightness(for displayID: CGDirectDisplayID) -> Float? {
        stateLock.withLock {
            states.removeValue(forKey: displayID)?.previousBrightness
        }
    }

    func isUsingMirrorFallback(displayID: CGDirectDisplayID) -> Bool {
        stateLock.withLock {
            states[displayID]?.mode == .mirrored
        }
    }

    func hasSettledIsolation(displayID: CGDirectDisplayID) -> Bool {
        stateLock.withLock {
            guard let state = states[displayID] else { return false }
            return state.isPersistent || state.mode == .mirrored
        }
    }

    func clearAll() -> [CGDirectDisplayID: Float] {
        stateLock.lock()
        defer { stateLock.unlock() }

        let previousStates = states
        for (displayID, state) in previousStates {
            switch state.mode {
            case .disconnected:
                _ = restoreDisconnectedDisplay(displayID: displayID)
            case .mirrored:
                _ = configureMirroring(displayID: displayID, mirrorTargetID: nil)
            }
            if waitForTargetState(displayID: displayID, blackoutEnabled: false) {
                states.removeValue(forKey: displayID)
            }
        }

        return previousStates.reduce(into: [:]) { result, entry in
            if states[entry.key] == nil, let brightness = entry.value.previousBrightness {
                result[entry.key] = brightness
            }
        }
    }

    func isRestored(displayID: CGDirectDisplayID) -> Bool {
        isDisplayRestored(displayID)
    }

    func removeRestoredStates(
        candidates: Set<CGDirectDisplayID>
    ) -> Set<CGDirectDisplayID> {
        stateLock.withLock {
            let restoredIDs = Set(candidates.filter {
                CGDisplayIsBuiltin($0) != 1 || isDisplayRestored($0)
            })
            for displayID in restoredIDs {
                states.removeValue(forKey: displayID)
            }
            return restoredIDs
        }
    }

    private func restoreDisconnectedDisplay(displayID: CGDirectDisplayID) -> Bool {
        guard !isDisplayRestored(displayID) else { return true }

        // Use a persistent restore only while the panel is still isolated so
        // the saved topology cannot disable it again at the next login window.
        let permanentRequestSucceeded = configureDisplay(
            displayID: displayID,
            enabled: true,
            completionOption: BuiltInDisplayConfigurationPolicy.restorationOption
        )
        if isDisplayRestored(displayID) {
            return true
        }

        AppLogger.ui.notice(
            "Permanent restore did not activate built-in display ID \(displayID); retrying for this session"
        )
        let sessionRequestSucceeded = configureDisplay(
            displayID: displayID,
            enabled: true,
            completionOption: BuiltInDisplayConfigurationPolicy.fallbackRestorationOption
        )
        return permanentRequestSucceeded || sessionRequestSucceeded
    }

    private func configureDisplay(
        displayID: CGDirectDisplayID,
        enabled: Bool,
        completionOption: CGConfigureOption = .forSession
    ) -> Bool {
        guard let configureDisplayEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return false
        }

        let configureResult = configureDisplayEnabled(config, displayID, enabled)
        guard configureResult == .success else {
            AppLogger.ui.error(
                "Display topology request failed for ID \(displayID), enabled: \(enabled, privacy: .public), error: \(configureResult.rawValue, privacy: .public)"
            )
            CGCancelDisplayConfiguration(config)
            return false
        }

        let completionResult = CGCompleteDisplayConfiguration(config, completionOption)
        if completionResult != .success {
            // WindowServer can apply this private operation while returning a
            // generic completion error. The configuration object is consumed by
            // CGCompleteDisplayConfiguration, so verification decides success.
            AppLogger.ui.notice(
                "Display topology completion failed for ID \(displayID), enabled: \(enabled, privacy: .public), error: \(completionResult.rawValue, privacy: .public)"
            )
            return false
        }
        return true
    }

    func allDisplayIDs() -> [CGDirectDisplayID] {
        guard let getDisplayList else {
            return Array(onlineDisplayIDs())
        }

        var count: UInt32 = 0
        guard getDisplayList(0, nil, &count) == .success, count > 0 else {
            return Array(onlineDisplayIDs())
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard getDisplayList(count, &ids, &count) == .success else {
            return Array(onlineDisplayIDs())
        }
        return Array(ids.prefix(Int(count))).filter { $0 != kCGNullDirectDisplay }
    }

    private func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            return []
        }
        return Set(ids.prefix(Int(count)))
    }

    private func isDisplayRestored(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(displayID) == 1
            && CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay
    }

    private func waitForTargetState(
        displayID: CGDirectDisplayID,
        blackoutEnabled: Bool
    ) -> Bool {
        for delay in [0, 20_000, 80_000, 200_000] as [useconds_t] {
            if delay > 0 {
                usleep(delay)
            }
            if BuiltInDisplayTopologyResult.reachedTarget(
                targetBlackoutEnabled: blackoutEnabled,
                displayIsRestored: isDisplayRestored(displayID)
            ) {
                return true
            }
        }
        return false
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

    deinit {
        for handle in frameworkHandles {
            dlclose(handle)
        }
    }
}
