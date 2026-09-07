import Foundation
import Testing
@testable import FanshuMonitor

struct MetricIDTests {
    @Test func codableRepresentationRemainsAPlainString() throws {
        let data = try JSONEncoder().encode(MetricID.weekly)
        #expect(String(decoding: data, as: UTF8.self) == "\"weekly\"")
        #expect(try JSONDecoder().decode(MetricID.self, from: data) == .weekly)
    }

    @Test func stringLiteralKeepsUnknownFutureMetricsCompatible() {
        let metric: MetricID = "future-metric"
        #expect(metric.rawValue == "future-metric")
    }
}

struct PreferencesCodecTests {
    private struct Payload: Codable, Equatable {
        let enabled: Bool
        let ids: [MetricID]
    }

    @Test func roundTripsTypedPreferences() throws {
        let payload = Payload(enabled: true, ids: [.weekly, .activeTasks])
        let data = try #require(PreferencesCodec.encode(payload, key: "test.payload"))
        let decoded = PreferencesCodec.decode(Payload.self, from: data, key: "test.payload")
        #expect(decoded == payload)
    }

    @Test func malformedPreferencesFailWithoutCrashing() {
        let decoded = PreferencesCodec.decode(
            Payload.self,
            from: Data("not-json".utf8),
            key: "test.malformed"
        )
        #expect(decoded == nil)
    }
}

struct PowerFlowAnimationPolicyTests {
    @Test func presentationAblationPreservesOutput() {
        let metrics: [MonitorMetric] = [
            .init(name: "adapter-input", value: "47.6 W"),
            .init(name: "system-load", value: "72.1 W"),
            .init(name: "battery-flow", value: "-24.5 W")
        ]
        let iterations = 10_000
        let clock = ContinuousClock()
        var repeatedChecksum = 0.0
        let repeatedTime = clock.measure {
            for _ in 0..<iterations {
                repeatedChecksum += BatteryPowerFlowPresentation(metrics: metrics, isConnectedToPower: true).adapterInputWatts ?? 0
                repeatedChecksum += BatteryPowerFlowPresentation(metrics: metrics, isConnectedToPower: true).systemLoadWatts ?? 0
                repeatedChecksum += BatteryPowerFlowPresentation(metrics: metrics, isConnectedToPower: true).batteryMagnitude ?? 0
            }
        }
        var sharedChecksum = 0.0
        let sharedTime = clock.measure {
            for _ in 0..<iterations {
                let value = BatteryPowerFlowPresentation(metrics: metrics, isConnectedToPower: true)
                sharedChecksum += value.adapterInputWatts ?? 0
                sharedChecksum += value.systemLoadWatts ?? 0
                sharedChecksum += value.batteryMagnitude ?? 0
            }
        }
        #expect(repeatedChecksum == sharedChecksum)
        print("Power presentation ablation: repeated=\(repeatedTime), shared=\(sharedTime), iterations=\(iterations)")
    }

    @Test func usesASubtleCompositorAnimationCycle() {
        #expect(PowerFlowAnimationPolicy.cycleDuration >= 0.8)
        #expect(PowerFlowAnimationPolicy.cycleDuration <= 1.5)
    }

    @Test func routesSystemFlowToTheUpperCoreAnimationBranch() {
        let endpoints = PowerFlowAnimationPolicy.endpointY(height: 54)
        #expect(endpoints.system > endpoints.battery)
    }

    @Test func animatesOnlyForVisibleActivePowerFlow() {
        #expect(PowerFlowAnimationPolicy.shouldAnimate(
            isActive: true,
            reduceMotion: false,
            hasActiveFlow: true
        ))
        #expect(!PowerFlowAnimationPolicy.shouldAnimate(
            isActive: false,
            reduceMotion: false,
            hasActiveFlow: true
        ))
        #expect(!PowerFlowAnimationPolicy.shouldAnimate(
            isActive: true,
            reduceMotion: true,
            hasActiveFlow: true
        ))
        #expect(!PowerFlowAnimationPolicy.shouldAnimate(
            isActive: true,
            reduceMotion: false,
            hasActiveFlow: false
        ))
    }
}

struct BatteryBreathingAnimationPolicyTests {
    @Test func animatesOnlyWhileThePanelIsVisibleAndBatteryIsCharging() {
        #expect(BatteryBreathingAnimationPolicy.shouldAnimate(
            isPanelVisible: true,
            isActivelyCharging: true
        ))
        #expect(!BatteryBreathingAnimationPolicy.shouldAnimate(
            isPanelVisible: false,
            isActivelyCharging: true
        ))
        #expect(!BatteryBreathingAnimationPolicy.shouldAnimate(
            isPanelVisible: true,
            isActivelyCharging: false
        ))
    }
}
