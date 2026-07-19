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

struct DisplaySoftwareDimmingWindowPolicyTests {
    @Test func overlayStaysAboveScreenSaverWindows() {
        #expect(DisplaySoftwareDimmingWindowPolicy.level.rawValue > NSWindow.Level.screenSaver.rawValue)
    }
}
