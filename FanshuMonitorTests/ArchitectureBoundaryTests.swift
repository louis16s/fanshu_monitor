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

struct SystemCapabilityRegistryTests {
    @Test func tracksAvailabilityPerCapability() {
        let registry = SystemCapabilityRegistry()
        #expect(registry.status(for: .nativeScreenLock) == .unknown)

        registry.reportAvailable(.nativeScreenLock)
        registry.reportUnavailable(.displayIsolation, reason: "missing symbol")

        #expect(registry.status(for: .nativeScreenLock) == .available)
        #expect(
            registry.status(for: .displayIsolation)
                == .unavailable(reason: "missing symbol")
        )
    }
}

struct PowerFlowAnimationPolicyTests {
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
