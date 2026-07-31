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
