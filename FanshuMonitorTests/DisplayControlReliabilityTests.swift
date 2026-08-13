import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import FanshuMonitor

struct DDCFaultRegistryTests {
    private let key = ControlKey(displayID: 1, control: .brightness)

    @Test func startsEnabled() {
        let registry = DDCFaultRegistry()

        #expect(!registry.isDisabled(key))
        #expect(!registry.shouldUseLongerDelay(key))
    }

    @Test func usesLongerDelayAfterThreeReadFailures() {
        let registry = DDCFaultRegistry()

        registry.recordReadFailure(key)
        registry.recordReadFailure(key)
        #expect(!registry.shouldUseLongerDelay(key))

        registry.recordReadFailure(key)
        #expect(registry.shouldUseLongerDelay(key))
    }

    @Test func disablesAfterFiveReadFailures() {
        let registry = DDCFaultRegistry()

        for _ in 0..<4 {
            registry.recordReadFailure(key)
        }
        #expect(!registry.isDisabled(key))

        registry.recordReadFailure(key)
        #expect(registry.isDisabled(key))
    }

    @Test func disablesAfterTenWriteFailures() {
        let registry = DDCFaultRegistry()

        for _ in 0..<9 {
            registry.recordWriteFailure(key)
        }
        #expect(!registry.isDisabled(key))

        registry.recordWriteFailure(key)
        #expect(registry.isDisabled(key))
    }

    @Test func successClearsFaultState() {
        let registry = DDCFaultRegistry()

        for _ in 0..<5 {
            registry.recordReadFailure(key)
        }
        #expect(registry.isDisabled(key))

        registry.recordReadSuccess(key)
        #expect(!registry.isDisabled(key))
        #expect(!registry.shouldUseLongerDelay(key))
    }

    @Test func resetClearsSingleDisplay() {
        let registry = DDCFaultRegistry()
        let other = ControlKey(displayID: 2, control: .brightness)

        for _ in 0..<5 {
            registry.recordReadFailure(key)
            registry.recordReadFailure(other)
        }

        registry.reset(displayID: 1)
        #expect(!registry.isDisabled(key))
        #expect(registry.isDisabled(other))
    }
}

private final class DDCRegistryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    func now() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

struct DDCTransportChannelRegistryTests {
    @Test func timeoutQuarantinesTheCurrentGeneration() {
        let clock = DDCRegistryClock()
        let registry = DDCTransportChannelRegistry(cooldown: 10, now: clock.now)
        let lease = registry.lease(for: 1)

        #expect(lease != nil)
        registry.recordTimeout(displayID: 1, generation: lease?.generation ?? 0)
        #expect(registry.isQuarantined(displayID: 1))
        #expect(registry.lease(for: 1) == nil)
    }

    @Test func oneRecoveryUsesANewQueueGenerationThenStopsRepeatedLeaks() {
        let clock = DDCRegistryClock()
        let registry = DDCTransportChannelRegistry(
            cooldown: 10,
            maximumRecoveries: 1,
            now: clock.now
        )
        let first = registry.lease(for: 1)
        registry.recordTimeout(displayID: 1, generation: first?.generation ?? 0)
        clock.advance(by: 11)

        let second = registry.lease(for: 1)
        #expect(second?.generation == 1)
        registry.recordTimeout(displayID: 1, generation: second?.generation ?? 0)
        clock.advance(by: 11)
        #expect(registry.lease(for: 1) == nil)

        registry.reset(displayID: 1)
        #expect(registry.lease(for: 1)?.generation == 0)
    }
}

struct DisplayClassifierTests {
    @Test func builtInDisplayWinsBeforeOtherSignals() {
        let classifier = makeClassifier(
            isBuiltIn: true,
            info: ["kCGDisplayIsVirtualDevice": true],
            hasNativeBrightness: false
        )

        #expect(classifier.classify(displayID: 1) == .builtIn)
    }

    @Test func virtualDisplayIsDetected() {
        let classifier = makeClassifier(
            info: ["kCGDisplayIsVirtualDevice": true],
            hasNativeBrightness: false
        )

        #expect(classifier.classify(displayID: 1) == .virtual)
    }

    @Test func airPlayDisplayIsTreatedAsVirtual() {
        let classifier = makeClassifier(
            info: ["kCGDisplayIsAirPlay": NSNumber(value: true)],
            hasNativeBrightness: false
        )

        #expect(classifier.classify(displayID: 1) == .virtual)
    }

    @Test func dummyDisplayIsDetectedByName() {
        let classifier = makeClassifier(
            info: ["DisplayProductName": ["en_US": "Virtual Dummy Display"]],
            hasNativeBrightness: false
        )

        #expect(classifier.classify(displayID: 1) == .dummy)
    }

    @Test func dummyDisplayIsDetectedByVendor() {
        let classifier = makeClassifier(
            info: ["DisplayVendorID": NSNumber(value: 0xF0F0)],
            hasNativeBrightness: false
        )

        #expect(classifier.classify(displayID: 1) == .dummy)
    }

    @Test func appleNativeBrightnessDisplayIsDetected() {
        let classifier = makeClassifier(hasNativeBrightness: true)

        #expect(classifier.classify(displayID: 1) == .appleNative)
    }

    @Test func ordinaryExternalDisplayFallsBackToDDC() {
        let classifier = makeClassifier(hasNativeBrightness: false)

        #expect(classifier.classify(displayID: 1) == .externalDDC)
    }

    private func makeClassifier(
        isBuiltIn: Bool = false,
        info: [String: Any] = [:],
        hasNativeBrightness: Bool
    ) -> DisplayClassifier {
        DisplayClassifier(
            probeNativeBrightness: { _ in hasNativeBrightness },
            isBuiltInDisplay: { _ in isBuiltIn },
            infoProvider: { _ in info }
        )
    }
}

struct DisplayBrightnessCapabilityTests {
    @Test func appleNativeDisplayRequiresNativeBrightnessProbe() {
        #expect(DisplayControlService.supportsBrightness(
            displayKind: .appleNative,
            nativeBrightnessAvailable: true,
            ddcBrightnessAvailable: false,
            ddcBrightnessPreviouslyVerified: false,
            isTemporarilyDisabled: false
        ))
        #expect(!DisplayControlService.supportsBrightness(
            displayKind: .appleNative,
            nativeBrightnessAvailable: false,
            ddcBrightnessAvailable: true,
            ddcBrightnessPreviouslyVerified: true,
            isTemporarilyDisabled: false
        ))
    }

    @Test func ddcServiceWithoutReadableOrKnownBrightnessIsNotControllable() {
        #expect(!DisplayControlService.supportsBrightness(
            displayKind: .externalDDC,
            nativeBrightnessAvailable: false,
            ddcBrightnessAvailable: false,
            ddcBrightnessPreviouslyVerified: false,
            isTemporarilyDisabled: false
        ))
    }

    @Test func previouslyVerifiedDDCDisplaySurvivesATransientReadFailure() {
        #expect(DisplayControlService.supportsBrightness(
            displayKind: .externalDDC,
            nativeBrightnessAvailable: false,
            ddcBrightnessAvailable: false,
            ddcBrightnessPreviouslyVerified: true,
            isTemporarilyDisabled: false
        ))
    }

    @Test func faultedDDCDisplayIsNotControllable() {
        #expect(!DisplayControlService.supportsBrightness(
            displayKind: .externalDDC,
            nativeBrightnessAvailable: false,
            ddcBrightnessAvailable: true,
            ddcBrightnessPreviouslyVerified: true,
            isTemporarilyDisabled: true
        ))
    }
}

struct DisplaySoftwareDimmingWindowPolicyTests {
    @Test func overlayStaysAboveScreenSaverWindows() {
        #expect(DisplaySoftwareDimmingWindowPolicy.level.rawValue > NSWindow.Level.screenSaver.rawValue)
    }
}

struct DisplayValueChangePolicyTests {
    @Test func unchangedNativeBrightnessDoesNotRepublishDisplayState() {
        #expect(!DisplayValueChangePolicy.shouldPublish(current: 50, next: 50))
        #expect(!DisplayValueChangePolicy.shouldPublish(current: 50, next: 50.05))
        #expect(DisplayValueChangePolicy.shouldPublish(current: 50, next: 50.2))
    }

    @Test func nativeBrightnessUsesALightweightTwoHundredMillisecondSync() {
        #expect(DisplayNativeBrightnessSyncPolicy.intervalMilliseconds == 200)
        #expect(DisplayNativeBrightnessSyncPolicy.shouldRun(
            panelVisible: true,
            moduleVisible: true,
            brightnessControlEnabled: true,
            hasNativeBrightnessDisplay: true
        ))
        #expect(!DisplayNativeBrightnessSyncPolicy.shouldRun(
            panelVisible: false,
            moduleVisible: true,
            brightnessControlEnabled: true,
            hasNativeBrightnessDisplay: true
        ))
        #expect(!DisplayNativeBrightnessSyncPolicy.shouldRun(
            panelVisible: true,
            moduleVisible: true,
            brightnessControlEnabled: true,
            hasNativeBrightnessDisplay: false
        ))
    }
}

struct DisplayHeaderBrightnessPolicyTests {
    @Test func showsBrightnessForOneWorkingControllableDisplay() {
        let display = makeDisplay(id: 1, isBuiltIn: true, supportsBrightness: true)

        #expect(DisplayHeaderBrightnessPolicy.targetID(
            displays: [display],
            blackedOutDisplayIDs: []
        ) == 1)
    }

    @Test func hidesBrightnessWhenMultipleDisplaysAreWorking() {
        #expect(DisplayHeaderBrightnessPolicy.targetID(
            displays: [
                makeDisplay(id: 1, isBuiltIn: true, supportsBrightness: true),
                makeDisplay(id: 2, isBuiltIn: false, supportsBrightness: true)
            ],
            blackedOutDisplayIDs: []
        ) == nil)
    }

    @Test func ignoresAClosedBuiltInDisplayWhenAnExternalDisplayIsWorking() {
        #expect(DisplayHeaderBrightnessPolicy.targetID(
            displays: [
                makeDisplay(id: 1, isBuiltIn: true, supportsBrightness: false),
                makeDisplay(id: 2, isBuiltIn: false, supportsBrightness: true)
            ],
            blackedOutDisplayIDs: [1]
        ) == 2)
    }

    @Test func hidesBrightnessWhenTheOnlyWorkingDisplayIsNotControllable() {
        #expect(DisplayHeaderBrightnessPolicy.targetID(
            displays: [makeDisplay(id: 2, isBuiltIn: false, supportsBrightness: false)],
            blackedOutDisplayIDs: []
        ) == nil)
    }

    private func makeDisplay(
        id: CGDirectDisplayID,
        isBuiltIn: Bool,
        supportsBrightness: Bool
    ) -> ControlledDisplay {
        ControlledDisplay(
            id: id,
            storageID: "display-\(id)",
            name: "Display \(id)",
            kind: isBuiltIn ? .builtIn : .externalDDC,
            isBuiltIn: isBuiltIn,
            usesNativeBrightness: isBuiltIn,
            supportsBrightness: supportsBrightness,
            supportsVolume: false,
            supportsContrast: false,
            brightness: 50,
            volume: 0,
            contrast: 0,
            brightnessUnavailableReason: supportsBrightness ? nil : "不可用",
            volumeUnavailableReason: nil,
            contrastUnavailableReason: nil,
            capabilities: nil
        )
    }
}

struct DisplayCapabilityFormatterTests {
    @Test func formatsFixedAndVariableRefreshRates() {
        #expect(DisplayCapabilityFormatter.refreshRate(
            current: 60,
            maximumFramesPerSecond: 60,
            maximumRefreshInterval: 1.0 / 60.0
        ) == "60 Hz")
        #expect(DisplayCapabilityFormatter.refreshRate(
            current: 0,
            maximumFramesPerSecond: 120,
            maximumRefreshInterval: 1.0 / 48.0
        ) == "48–120 Hz")
    }

    @Test func buildsCompactCapabilitySummary() {
        let capabilities = DisplayCapabilities(
            resolution: DisplayCapabilityFormatter.resolution(width: 2560, height: 1440),
            refreshRate: "144 Hz",
            dynamicRange: "HDR",
            colorSpace: DisplayCapabilityFormatter.colorSpace("Display P3"),
            connection: DisplayCapabilityFormatter.connection(for: .externalDDC)
        )

        #expect(capabilities.summary == "2560×1440 · 144 Hz · HDR · Display P3")
        #expect(capabilities.connection == "DDC")
    }
}

struct BuiltInDisplayRestorePolicyTests {
    @Test func keepsAClosedBuiltInRowVisibleWhileBlackoutIsIntentional() {
        #expect(BuiltInDisplayPresentationPolicy.shouldKeepCachedRow(
            detectedBuiltInCount: 0,
            blackoutDesired: true,
            isolatedDisplayCount: 0,
            hasCachedDisplay: true
        ))
        #expect(BuiltInDisplayPresentationPolicy.shouldKeepCachedRow(
            detectedBuiltInCount: 0,
            blackoutDesired: false,
            isolatedDisplayCount: 1,
            hasCachedDisplay: true
        ))
    }

    @Test func doesNotKeepAStaleBuiltInRowAfterRestore() {
        #expect(!BuiltInDisplayPresentationPolicy.shouldKeepCachedRow(
            detectedBuiltInCount: 0,
            blackoutDesired: false,
            isolatedDisplayCount: 0,
            hasCachedDisplay: true
        ))
        #expect(!BuiltInDisplayPresentationPolicy.shouldKeepCachedRow(
            detectedBuiltInCount: 1,
            blackoutDesired: true,
            isolatedDisplayCount: 1,
            hasCachedDisplay: true
        ))
    }

    @Test func restoresWhenTheLastExternalDisplayDisconnects() {
        #expect(BuiltInDisplayRestorePolicy.shouldRestore(
            externalDisplayCount: 0,
            blackoutDesired: true,
            isolatedDisplayCount: 1
        ))
        #expect(BuiltInDisplayRestorePolicy.shouldRestore(
            externalDisplayCount: 0,
            blackoutDesired: false,
            isolatedDisplayCount: 1
        ))
    }

    @Test func leavesTheTopologyAloneWhenAnExternalDisplayRemains() {
        #expect(!BuiltInDisplayRestorePolicy.shouldRestore(
            externalDisplayCount: 1,
            blackoutDesired: true,
            isolatedDisplayCount: 1
        ))
        #expect(!BuiltInDisplayRestorePolicy.shouldRestore(
            externalDisplayCount: 0,
            blackoutDesired: false,
            isolatedDisplayCount: 0
        ))
    }

    @Test func externalDisconnectUsesThirtyFivePercentBrightness() {
        #expect(BuiltInDisplayRestorePolicy.disconnectedExternalBrightness == 35)
        #expect(BuiltInDisplayRestorePolicy.topologyWatchdogInterval >= 5)
        #expect(!BuiltInDisplayRestorePolicy.topologyRetryDelays.isEmpty)
        #expect(!BuiltInDisplayRestorePolicy.brightnessRetryDelays.isEmpty)
        #expect(BuiltInDisplayRestorePolicy.brightnessRetryDelays.first == 0)
        #expect(DisplayHardwareDisconnectRecoveryPolicy.confirmedRemovalDelay <= 0.06)
        #expect(
            DisplayHardwareDisconnectRecoveryPolicy.unknownChangeDelay
                > DisplayHardwareDisconnectRecoveryPolicy.confirmedRemovalDelay
        )
    }

    @Test func builtInIsolationAndSafetyRestoreSharePermanentScope() {
        #expect(
            BuiltInDisplayConfigurationPolicy.isolationOption.rawValue
                == CGConfigureOption.permanently.rawValue
        )
        #expect(
            BuiltInDisplayConfigurationPolicy.restorationOption.rawValue
                == CGConfigureOption.permanently.rawValue
        )
        #expect(
            BuiltInDisplayConfigurationPolicy.fallbackRestorationOption.rawValue
                == CGConfigureOption.forSession.rawValue
        )
    }

    @Test func preservesTheUserIntentWhileSafetyRestoreIsActive() {
        #expect(BuiltInBlackoutIntentPolicy.shouldSuspendForMissingExternal(
            externalDisplayCount: 0,
            blackoutDesired: true,
            isolatedDisplayCount: 0,
            builtInDisplayIsOffline: false
        ))
        #expect(!BuiltInBlackoutIntentPolicy.shouldSuspendForMissingExternal(
            externalDisplayCount: 1,
            blackoutDesired: true,
            isolatedDisplayCount: 0,
            builtInDisplayIsOffline: false
        ))
        #expect(!BuiltInBlackoutIntentPolicy.shouldSuspendForMissingExternal(
            externalDisplayCount: 0,
            blackoutDesired: true,
            isolatedDisplayCount: 1,
            builtInDisplayIsOffline: true
        ))
    }
}

struct DisplayDisconnectRecoveryPolicyTests {
    @Test func forcesRestoreOnlyWhenTheKnownLastExternalDisplayIsRemoved() {
        #expect(DisplayDisconnectRecoveryPolicy.shouldForceRestore(
            isRemoval: true,
            removedDisplayID: 8,
            cachedBuiltInDisplayID: 1,
            knownExternalDisplayIDs: [8]
        ))
        #expect(!DisplayDisconnectRecoveryPolicy.shouldForceRestore(
            isRemoval: true,
            removedDisplayID: 8,
            cachedBuiltInDisplayID: 1,
            knownExternalDisplayIDs: [8, 9]
        ))
    }

    @Test func neverTreatsTheBuiltInDisplayRemovalAsAnExternalDisconnect() {
        #expect(!DisplayDisconnectRecoveryPolicy.shouldForceRestore(
            isRemoval: true,
            removedDisplayID: 1,
            cachedBuiltInDisplayID: 1,
            knownExternalDisplayIDs: [8]
        ))
        #expect(!DisplayDisconnectRecoveryPolicy.shouldForceRestore(
            isRemoval: false,
            removedDisplayID: 8,
            cachedBuiltInDisplayID: 1,
            knownExternalDisplayIDs: [8]
        ))
    }
}

struct DisplayHardwareTopologyTests {
    @Test func classifiesAppleSiliconDisplayServiceLocations() {
        #expect(DisplayHardwareServiceLocation(rawValue: "External") == .external)
        #expect(DisplayHardwareServiceLocation(rawValue: "embedded") == .embedded)
        #expect(DisplayHardwareServiceLocation(rawValue: nil) == .unknown)
        #expect(DisplayHardwareServiceLocation(rawValue: "Sidecar") == .unknown)
    }

    @Test func restoresOnlyWhenHardwareConfirmsTheLastExternalServiceIsGone() {
        #expect(DisplayHardwareDisconnectRecoveryPolicy.shouldForceRestore(
            externalServiceCount: 0,
            isolatedDisplayCount: 1,
            builtInDisplayIsOffline: true
        ))
        #expect(!DisplayHardwareDisconnectRecoveryPolicy.shouldForceRestore(
            externalServiceCount: 1,
            isolatedDisplayCount: 1,
            builtInDisplayIsOffline: true
        ))
        #expect(!DisplayHardwareDisconnectRecoveryPolicy.shouldAttemptWatchdogRecovery(
            externalServiceCount: 1,
            builtInRestoreRequired: true
        ))
        #expect(DisplayHardwareDisconnectRecoveryPolicy.shouldAttemptWatchdogRecovery(
            externalServiceCount: 0,
            builtInRestoreRequired: true
        ))
        #expect(DisplayHardwareDisconnectRecoveryPolicy.shouldAttemptWatchdogRecovery(
            externalServiceCount: nil,
            builtInRestoreRequired: true
        ))
        #expect(!DisplayHardwareDisconnectRecoveryPolicy.shouldForceRestore(
            externalServiceCount: nil,
            isolatedDisplayCount: 1,
            builtInDisplayIsOffline: true
        ))
        #expect(!DisplayHardwareDisconnectRecoveryPolicy.shouldForceRestore(
            externalServiceCount: 0,
            isolatedDisplayCount: 0,
            builtInDisplayIsOffline: false
        ))
    }

    @Test func externalConnectionFastPathStartsImmediatelyAndStaysBounded() {
        let delays = DisplayExternalConnectionPolicy.topologyRetryDelays
        #expect(delays.first == 0)
        #expect(delays == delays.sorted())
        #expect((delays.last ?? .infinity) <= 1.2)
        #expect(DisplayExternalConnectionPolicy.discoveryDelay < 0.15)
    }

    @Test func earlyWakeMaintenanceIsFastBoundedAndIgnoresSleepDisconnects() {
        let earlyDelays = DisplayWakeMaintenancePolicy.earlyRetryDelays
        let settledDelays = DisplayWakeMaintenancePolicy.settledRetryDelays

        #expect(earlyDelays.first == 0)
        #expect(earlyDelays == earlyDelays.sorted())
        #expect((earlyDelays.last ?? .infinity) <= 0.6)
        #expect(settledDelays.first == 0)
        #expect((settledDelays.last ?? .infinity) <= 0.8)
        #expect(!DisplayWakeMaintenancePolicy.shouldVerifyExternalDisconnect(
            isSystemSleeping: true
        ))
        #expect(DisplayWakeMaintenancePolicy.shouldVerifyExternalDisconnect(
            isSystemSleeping: false
        ))
    }

    @Test func earlyWakeMaintenanceRetriesUntilTopologyIsApplied() async {
        let recorder = WakeTopologyRecorder(succeedsAfter: 2)
        let coordinator = DisplayTopologyMaintenanceCoordinator(
            blackoutDesired: { true },
            reapplyTopology: { completion in
                completion(recorder.nextResult())
            },
            topologyApplied: { displayIDs in
                recorder.recordApplied(displayIDs)
            }
        )

        coordinator.handle(.willPowerOn)
        try? await Task.sleep(for: .milliseconds(180))

        #expect(recorder.attemptCount >= 2)
        #expect(recorder.appliedIDs == [42])
    }

    @Test func settledWakeEventDoesNotRepeatASuccessfulTopologyRequest() async {
        let recorder = WakeTopologyRecorder(succeedsAfter: 1)
        let coordinator = DisplayTopologyMaintenanceCoordinator(
            blackoutDesired: { true },
            reapplyTopology: { completion in
                completion(recorder.nextResult())
            },
            topologyApplied: { displayIDs in
                recorder.recordApplied(displayIDs)
            }
        )

        coordinator.handle(.willPowerOn)
        try? await Task.sleep(for: .milliseconds(40))
        coordinator.handle(.hasPoweredOn)
        try? await Task.sleep(for: .milliseconds(120))

        #expect(recorder.attemptCount == 1)
        #expect(recorder.appliedCount == 1)
    }

    @Test func externalConnectionMaintenanceStopsAfterSuccess() async {
        let recorder = WakeTopologyRecorder(succeedsAfter: 2)
        let coordinator = DisplayTopologyMaintenanceCoordinator(
            blackoutDesired: { true },
            reapplyTopology: { completion in
                completion(recorder.nextResult())
            },
            topologyApplied: { displayIDs in
                recorder.recordApplied(displayIDs)
            }
        )

        coordinator.requestExternalConnectionMaintenance()
        try? await Task.sleep(for: .milliseconds(260))

        #expect(recorder.attemptCount == 2)
        #expect(recorder.appliedCount == 1)
    }
}

private final class WakeTopologyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let succeedsAfter: Int
    private var attempts = 0
    private var storedAppliedIDs: Set<CGDirectDisplayID> = []
    private var appliedEvents = 0

    init(succeedsAfter: Int) {
        self.succeedsAfter = succeedsAfter
    }

    func nextResult() -> Set<CGDirectDisplayID> {
        lock.withLock {
            attempts += 1
            return attempts >= succeedsAfter ? [42] : []
        }
    }

    func recordApplied(_ displayIDs: Set<CGDirectDisplayID>) {
        lock.withLock {
            storedAppliedIDs = displayIDs
            appliedEvents += 1
        }
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    var appliedIDs: Set<CGDirectDisplayID> {
        lock.withLock { storedAppliedIDs }
    }

    var appliedCount: Int {
        lock.withLock { appliedEvents }
    }
}

private final class BuiltInBrightnessAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Float, CGDirectDisplayID)] = []

    func record(brightness: Float, displayID: CGDirectDisplayID) -> Bool {
        lock.withLock {
            values.append((brightness, displayID))
            return values.count >= 2
        }
    }

    var snapshot: [(Float, CGDirectDisplayID)] {
        lock.withLock { values }
    }
}

private final class BuiltInTopologyAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    func restore(brightness: Float) -> CGDirectDisplayID? {
        lock.withLock {
            attempts += 1
            guard attempts >= 2, abs(brightness - 0.35) < 0.0001 else { return nil }
            return 42
        }
    }

    var count: Int { lock.withLock { attempts } }
}

struct BuiltInDisconnectRecoveryTests {
    @Test func skipsRestoreWhileAnotherExternalDisplayRemains() async {
        let result: BuiltInDisconnectRecoveryResult = await withCheckedContinuation { continuation in
            DisplayControlWorker().restoreBuiltInAfterExternalDisconnect(
                brightnessPercent: 35,
                topologyRetryDelays: [0],
                brightnessRetryDelays: [0],
                hasExternalDisplay: { true },
                restoreTopology: { _ in 42 },
                applyBrightness: { _, _ in true },
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(result == .externalDisplayPresent)
    }

    @Test func forcedLastExternalRemovalBypassesAStaleExternalTopologySnapshot() async {
        let result: BuiltInDisconnectRecoveryResult = await withCheckedContinuation { continuation in
            DisplayControlWorker().restoreBuiltInAfterExternalDisconnect(
                brightnessPercent: 35,
                forceRestore: true,
                topologyRetryDelays: [0],
                brightnessRetryDelays: [0],
                hasExternalDisplay: { true },
                restoreTopology: { _ in 42 },
                applyBrightness: { _, _ in true },
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(result == .restored(displayID: 42))
    }

    @Test func restoresTopologyThenRetriesThirtyFivePercentBrightness() async {
        let recorder = BuiltInBrightnessAttemptRecorder()
        let result: BuiltInDisconnectRecoveryResult = await withCheckedContinuation { continuation in
            DisplayControlWorker().restoreBuiltInAfterExternalDisconnect(
                brightnessPercent: 35,
                topologyRetryDelays: [0],
                brightnessRetryDelays: [0, 0],
                hasExternalDisplay: { false },
                restoreTopology: { brightness in
                    abs(brightness - 0.35) < 0.0001 ? 42 : nil
                },
                applyBrightness: recorder.record,
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(result == .restored(displayID: 42))
        #expect(recorder.snapshot.count == 2)
        #expect(recorder.snapshot.allSatisfy { abs($0.0 - 0.35) < 0.0001 && $0.1 == 42 })
    }

    @Test func retriesTopologyUntilTheBuiltInDisplayIsActuallyVisible() async {
        let recorder = BuiltInTopologyAttemptRecorder()
        let result: BuiltInDisconnectRecoveryResult = await withCheckedContinuation { continuation in
            DisplayControlWorker().restoreBuiltInAfterExternalDisconnect(
                brightnessPercent: 35,
                topologyRetryDelays: [0, 0],
                brightnessRetryDelays: [0],
                hasExternalDisplay: { false },
                restoreTopology: recorder.restore,
                applyBrightness: { _, _ in true },
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(result == .restored(displayID: 42))
        #expect(recorder.count == 2)
    }

    @Test func doesNotReportACompleteRecoveryWhenBrightnessNeverApplies() async {
        let result: BuiltInDisconnectRecoveryResult = await withCheckedContinuation { continuation in
            DisplayControlWorker().restoreBuiltInAfterExternalDisconnect(
                brightnessPercent: 35,
                topologyRetryDelays: [0],
                brightnessRetryDelays: [0, 0],
                hasExternalDisplay: { false },
                restoreTopology: { _ in 42 },
                applyBrightness: { _, _ in false },
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(result == .brightnessPending(displayID: 42))
    }
}

struct BuiltInDisplayTopologyResultTests {
    @Test func acceptsOnlyAnObservedRestore() {
        #expect(BuiltInDisplayTopologyResult.reachedTarget(
            targetBlackoutEnabled: false,
            displayIsRestored: true
        ))
    }

    @Test func acceptsOnlyAnObservedBlackout() {
        #expect(BuiltInDisplayTopologyResult.reachedTarget(
            targetBlackoutEnabled: true,
            displayIsRestored: false
        ))
    }

    @Test func rejectsATopologyThatDidNotReachItsTargetState() {
        #expect(!BuiltInDisplayTopologyResult.reachedTarget(
            targetBlackoutEnabled: false,
            displayIsRestored: false
        ))
        #expect(!BuiltInDisplayTopologyResult.reachedTarget(
            targetBlackoutEnabled: true,
            displayIsRestored: true
        ))
    }
}

struct BuiltInDisplayRecoverySnapshotTests {
    @Test func persistsStableIdentityRuntimeIDAndBrightness() throws {
        let identity = BuiltInDisplayIdentity(
            vendorID: 1,
            modelID: 2,
            serialNumber: 3,
            unitNumber: 4
        )
        let snapshot = BuiltInDisplayRecoverySnapshot(
            identity: identity,
            lastRuntimeID: 42,
            brightness: 0.35
        )

        let decoded = try JSONDecoder().decode(
            BuiltInDisplayRecoverySnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded == snapshot)
        #expect(decoded.schemaVersion == BuiltInDisplayRecoverySnapshot.schemaVersion)
    }
}

struct DisplayControlWorkerTests {
    private let key = ControlKey(displayID: 1, control: .brightness)

    @Test func orderedKeyboardWritesPreserveEveryLevel() {
        let worker = DisplayControlWorker()
        let recorder = ThreadSafeValues()
        let group = DispatchGroup()
        let levels = [20.0, 25.0, 30.0, 35.0]

        for (sequence, level) in levels.enumerated() {
            group.enter()
            worker.setValue(
                level,
                for: key,
                sequence: UInt64(sequence + 1),
                mode: .ordered,
                performWrite: { value in
                    recorder.append(value)
                    return true
                },
                completion: { _ in group.leave() }
            )
        }

        #expect(group.wait(timeout: .now() + 3) == .success)
        #expect(recorder.values == levels)
    }

    @Test func coalescedSliderWritesOnlyTheLatestLevel() {
        let worker = DisplayControlWorker()
        let recorder = ThreadSafeValues()
        let completion = DispatchSemaphore(value: 0)

        for (sequence, level) in [20.0, 25.0, 30.0].enumerated() {
            worker.setValue(
                level,
                for: key,
                sequence: UInt64(sequence + 1),
                mode: .coalesced,
                performWrite: { value in
                    recorder.append(value)
                    return true
                },
                completion: { _ in completion.signal() }
            )
        }

        #expect(completion.wait(timeout: .now() + 3) == .success)
        #expect(recorder.values == [30])
    }

    @Test func slowDisplayDoesNotBlockAnotherDisplay() {
        let worker = DisplayControlWorker()
        let slowStarted = DispatchSemaphore(value: 0)
        let slowFinished = DispatchSemaphore(value: 0)
        let fastFinished = DispatchSemaphore(value: 0)

        worker.setValue(
            25,
            for: ControlKey(displayID: 1, control: .brightness),
            sequence: 1,
            mode: .ordered,
            performWrite: { _ in
                slowStarted.signal()
                Thread.sleep(forTimeInterval: 0.8)
                return true
            },
            completion: { _ in slowFinished.signal() }
        )
        #expect(slowStarted.wait(timeout: .now() + 1) == .success)

        worker.setValue(
            25,
            for: ControlKey(displayID: 2, control: .brightness),
            sequence: 2,
            mode: .ordered,
            performWrite: { _ in true },
            completion: { _ in fastFinished.signal() }
        )

        #expect(fastFinished.wait(timeout: .now() + 0.5) == .success)
        #expect(slowFinished.wait(timeout: .now() + 1) == .success)
    }

    @Test func nativeBrightnessReadWaitsForPendingWriteOnTheSameDisplay() {
        let worker = DisplayControlWorker()
        let writeStarted = DispatchSemaphore(value: 0)
        let allowWriteToFinish = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let readFinished = DispatchSemaphore(value: 0)
        let recorder = ThreadSafeValues()

        worker.setValue(
            65,
            for: key,
            sequence: 1,
            mode: .ordered,
            performWrite: { value in
                writeStarted.signal()
                _ = allowWriteToFinish.wait(timeout: .now() + 2)
                recorder.append(value)
                return true
            },
            completion: { _ in writeFinished.signal() }
        )
        #expect(writeStarted.wait(timeout: .now() + 1) == .success)

        worker.readNativeBrightness(
            displayID: key.displayID,
            performRead: {
                recorder.append(66)
                return 66
            },
            completion: { _ in readFinished.signal() }
        )

        #expect(readFinished.wait(timeout: .now() + 0.1) == .timedOut)
        allowWriteToFinish.signal()
        #expect(writeFinished.wait(timeout: .now() + 1) == .success)
        #expect(readFinished.wait(timeout: .now() + 1) == .success)
        #expect(recorder.values == [65, 66])
    }

    @Test func slowDiscoveryDoesNotBlockNativeBrightnessOnAnotherDisplay() {
        let worker = DisplayControlWorker()
        let discoveryStarted = DispatchSemaphore(value: 0)
        let allowDiscoveryToFinish = DispatchSemaphore(value: 0)
        let discoveryFinished = DispatchSemaphore(value: 0)
        let brightnessFinished = DispatchSemaphore(value: 0)

        worker.refresh(
            activeControls: [.brightness],
            performDiscovery: {
                discoveryStarted.signal()
                _ = allowDiscoveryToFinish.wait(timeout: .now() + 2)
                return []
            },
            completion: { _ in discoveryFinished.signal() }
        )
        #expect(discoveryStarted.wait(timeout: .now() + 1) == .success)

        worker.readNativeBrightness(
            displayID: 2,
            performRead: { 55 },
            completion: { _ in brightnessFinished.signal() }
        )

        #expect(brightnessFinished.wait(timeout: .now() + 0.5) == .success)
        allowDiscoveryToFinish.signal()
        #expect(discoveryFinished.wait(timeout: .now() + 1) == .success)
    }

    @Test func displayDiscoveriesAreSerialized() {
        let worker = DisplayControlWorker()
        let firstStarted = DispatchSemaphore(value: 0)
        let allowFirstToFinish = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)

        worker.refresh(
            activeControls: [.brightness],
            performDiscovery: {
                firstStarted.signal()
                _ = allowFirstToFinish.wait(timeout: .now() + 2)
                return []
            },
            completion: { _ in }
        )
        #expect(firstStarted.wait(timeout: .now() + 1) == .success)

        worker.refresh(
            activeControls: [.brightness, .contrast],
            performDiscovery: {
                secondStarted.signal()
                return []
            },
            completion: { _ in secondFinished.signal() }
        )

        #expect(secondStarted.wait(timeout: .now() + 0.1) == .timedOut)
        allowFirstToFinish.signal()
        #expect(secondStarted.wait(timeout: .now() + 1) == .success)
        #expect(secondFinished.wait(timeout: .now() + 1) == .success)
    }

    @Test func matchingDiscoveryRequestsShareOneHardwareScan() {
        let worker = DisplayControlWorker()
        let scans = ThreadSafeCount()
        let firstStarted = DispatchSemaphore(value: 0)
        let allowFirstToFinish = DispatchSemaphore(value: 0)
        let completions = DispatchGroup()
        completions.enter()
        completions.enter()

        worker.refresh(
            activeControls: [.brightness],
            performDiscovery: {
                scans.increment()
                firstStarted.signal()
                _ = allowFirstToFinish.wait(timeout: .now() + 2)
                return []
            },
            completion: { _ in completions.leave() }
        )
        #expect(firstStarted.wait(timeout: .now() + 1) == .success)

        worker.refresh(
            activeControls: [.brightness],
            performDiscovery: {
                scans.increment()
                return []
            },
            completion: { _ in completions.leave() }
        )

        allowFirstToFinish.signal()
        #expect(completions.wait(timeout: .now() + 1) == .success)
        #expect(scans.value == 1)
    }
}

private final class ThreadSafeValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.withLock { storage }
    }

    func append(_ value: Double) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private final class ThreadSafeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}
