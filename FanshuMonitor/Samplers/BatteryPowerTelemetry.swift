import Foundation
import IOKit

nonisolated struct BatteryPowerTelemetry: Equatable, Sendable {
    let adapterInputWatts: Double?
    let systemLoadWatts: Double?
    let batteryWatts: Double?

    init(
        adapterInputMilliwatts: Double?,
        systemLoadMilliwatts: Double?,
        batteryMilliwatts: Double?,
        adapterCurrentMilliamps: Double? = nil,
        adapterVoltageMillivolts: Double? = nil
    ) {
        adapterInputWatts = Self.resolvedAdapterInputWatts(
            directMilliwatts: adapterInputMilliwatts,
            currentMilliamps: adapterCurrentMilliamps,
            voltageMillivolts: adapterVoltageMillivolts
        )
        systemLoadWatts = Self.watts(systemLoadMilliwatts, allowsNegative: false)
        batteryWatts = Self.watts(batteryMilliwatts, allowsNegative: true)
    }

    var resolvedSystemLoadWatts: Double? {
        if let systemLoadWatts, systemLoadWatts >= 0.05 {
            return systemLoadWatts
        }
        if let adapterInputWatts, adapterInputWatts > 0 {
            return nonZeroWatts(adapterInputWatts - (batteryWatts ?? 0))
        }
        if let batteryWatts, batteryWatts < 0 {
            return abs(batteryWatts)
        }
        return nil
    }

    var chargingWatts: Double? {
        guard let batteryWatts, batteryWatts > 0 else { return nil }
        return batteryWatts
    }

    var hasAnyValue: Bool {
        adapterInputWatts != nil || systemLoadWatts != nil || batteryWatts != nil
    }

    static func batteryFlowText(_ watts: Double?) -> String {
        guard let watts, watts.isFinite else { return "--" }
        if abs(watts) < 0.05 { return "0 W" }
        return String(format: "%+.1f W", watts)
    }

    private static func watts(_ milliwatts: Double?, allowsNegative: Bool) -> Double? {
        guard let milliwatts, milliwatts.isFinite else { return nil }
        let watts = milliwatts / 1_000
        return allowsNegative ? watts : max(0, watts)
    }

    private static func resolvedAdapterInputWatts(
        directMilliwatts: Double?,
        currentMilliamps: Double?,
        voltageMillivolts: Double?
    ) -> Double? {
        let directWatts = watts(directMilliwatts, allowsNegative: false)
        guard let currentMilliamps,
              let voltageMillivolts,
              currentMilliamps.isFinite,
              voltageMillivolts.isFinite,
              currentMilliamps > 0,
              voltageMillivolts > 0 else {
            return directWatts
        }

        // Some Apple Silicon systems expose SystemPowerIn as zero while the
        // input current and voltage remain available and accurate.
        let derivedWatts = currentMilliamps * voltageMillivolts / 1_000_000
        guard derivedWatts.isFinite, derivedWatts > 0 else {
            return directWatts
        }
        return (directWatts ?? 0) > 0.05 ? directWatts : derivedWatts
    }
}

nonisolated enum BatteryPowerTelemetryReader {
    static func readCurrent() -> BatteryPowerTelemetry? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return read(service: service)
    }

    static func read(service: io_service_t) -> BatteryPowerTelemetry? {
        guard let values = IORegistryEntryCreateCFProperty(
            service,
            "PowerTelemetryData" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let telemetry = BatteryPowerTelemetry(
            adapterInputMilliwatts: signedDoubleValue(values["SystemPowerIn"]),
            systemLoadMilliwatts: signedDoubleValue(values["SystemLoad"]),
            batteryMilliwatts: signedDoubleValue(values["BatteryPower"]),
            adapterCurrentMilliamps: signedDoubleValue(values["SystemCurrentIn"]),
            adapterVoltageMillivolts: signedDoubleValue(values["SystemVoltageIn"])
        )
        return telemetry.hasAnyValue ? telemetry : nil
    }
}
