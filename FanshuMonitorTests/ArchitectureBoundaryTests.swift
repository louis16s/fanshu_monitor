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
