import Darwin
import Foundation
import IOKit
import IOKit.ps
import OSLog

nonisolated enum BatterySamplingPolicy {
    static func shouldCollectTelemetry(context: MonitorSamplingContext) -> Bool {
        context.panelVisible
    }

    static func shouldCollectSmartDetails(context: MonitorSamplingContext) -> Bool {
        shouldCollectTelemetry(context: context) && !context.prioritizesFirstPaint
    }
}

nonisolated final class BatterySampler: MonitorSampler {
    var kind: MonitorKind { .battery }

    private var powerTelemetryService: io_service_t = IO_OBJECT_NULL
    private var lastKnownSystemPowerWatts: Double?
    private var didReportPowerSourceFailure = false
    private var cachedSmartBatteryInfo: (value: SmartBatteryInfo, refreshedAt: Date)?
    private let smartBatteryRefreshInterval: TimeInterval = 5

    deinit {
        if powerTelemetryService != IO_OBJECT_NULL {
            IOObjectRelease(powerTelemetryService)
        }
    }

    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
            if !didReportPowerSourceFailure {
                AppLogger.sampler.error("BatterySampler failed to read power source info")
                didReportPowerSourceFailure = true
            }
            return previous ?? MonitorModule.placeholder(kind: .battery)
        }
        didReportPowerSourceFailure = false

        let current = doubleValue(description[kIOPSCurrentCapacityKey]) ?? 0
        let maxCapacity = doubleValue(description[kIOPSMaxCapacityKey]) ?? 100
        let percentage = maxCapacity > 0 ? min(100, max(0, current / maxCapacity * 100)) : 0
        let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false
        let sourceState = description[kIOPSPowerSourceStateKey] as? String
        let connected = sourceState == kIOPSACPowerValue

        let shouldCollectTelemetry = BatterySamplingPolicy.shouldCollectTelemetry(context: context)
        let shouldCollectSmartDetails = BatterySamplingPolicy.shouldCollectSmartDetails(context: context)
        let smart = shouldCollectSmartDetails ? smartBatteryInfo(at: Date()) : nil
        let powerFlow = shouldCollectTelemetry ? powerTelemetry() : nil
        let adapterWatts = smart?.adapterWatts ?? (shouldCollectTelemetry ? externalAdapterWatts() : nil)
        let chargingPower = connected
            ? (isCharging ? powerFlow?.chargingWatts ?? smart?.chargingPowerWatts : 0)
            : nil
        let systemPower = stableSystemPowerWatts(
            fresh: powerFlow?.resolvedSystemLoadWatts,
            previous: previous
        )

        return MonitorModule(
            kind: .battery,
            value: percentage,
            summary: percent(percentage),
            metrics: [
                MonitorMetric(name: "type", value: "battery"),
                MonitorMetric(name: "status", value: isCharging ? "charging" : (connected ? "ac-power" : "on-battery")),
                MonitorMetric(name: "adapter", value: connected
                    ? telemetryValue(
                        "adapter",
                        freshValue: Self.adapterMetricValue(isConnected: true, watts: adapterWatts),
                        previous: previous,
                        shouldCollect: shouldCollectTelemetry
                    )
                    : Self.adapterMetricValue(isConnected: false, watts: nil)),
                MonitorMetric(
                    name: "charging-power",
                    value: connected
                        ? telemetryValue(
                            "charging-power",
                            freshValue: wattStringAllowZero(chargingPower),
                            previous: previous,
                            shouldCollect: shouldCollectTelemetry
                        )
                        : "--"
                ),
                MonitorMetric(name: "power", value: telemetryValue(
                    "power",
                    freshValue: wattString(systemPower),
                    previous: previous,
                    shouldCollect: shouldCollectTelemetry
                )),
                MonitorMetric(name: "adapter-input", value: telemetryValue(
                    "adapter-input",
                    freshValue: wattStringAllowZero(powerFlow?.adapterInputWatts),
                    previous: previous,
                    shouldCollect: shouldCollectTelemetry
                )),
                MonitorMetric(name: "system-load", value: telemetryValue(
                    "system-load",
                    freshValue: wattString(systemPower),
                    previous: previous,
                    shouldCollect: shouldCollectTelemetry
                )),
                MonitorMetric(name: "battery-flow", value: telemetryValue(
                    "battery-flow",
                    freshValue: BatteryPowerTelemetry.batteryFlowText(powerFlow?.batteryWatts),
                    previous: previous,
                    shouldCollect: shouldCollectTelemetry
                )),
                MonitorMetric(name: "health", value: telemetryValue(
                    "health",
                    freshValue: smart?.healthPercent.map(percent) ?? "--",
                    previous: previous,
                    shouldCollect: shouldCollectTelemetry
                )),
                MonitorMetric(name: "cycle-count", value: telemetryValue(
                    "cycle-count",
                    freshValue: smart?.cycleCount.map { "\($0)" } ?? "--",
                    previous: previous,
                    shouldCollect: shouldCollectTelemetry
                )),
                MonitorMetric(name: "temperature", value: telemetryValue(
                    "temperature",
                    freshValue: smart?.temperatureCelsius.map { "\(String(format: "%.0f", $0))°C" } ?? "--",
                    previous: previous,
                    shouldCollect: shouldCollectTelemetry
                ))
            ],
            samples: seedSamples(percentage)
        )
    }

    private func telemetryValue(
        _ name: String,
        freshValue: String,
        previous: MonitorModule?,
        shouldCollect: Bool
    ) -> String {
        if shouldCollect {
            if freshValue != "--" {
                return freshValue
            }
            return previous?.metrics.first { $0.name == name }?.value ?? freshValue
        }
        return previous?.metrics.first { $0.name == name }?.value ?? "--"
    }

    static func adapterMetricValue(isConnected: Bool, watts: Double?) -> String {
        guard isConnected else {
            return "not-connected"
        }
        return wattString(watts, rounded: true)
    }

    private func stableSystemPowerWatts(
        fresh: Double?,
        previous: MonitorModule?
    ) -> Double? {
        let previousMetric = previous?.metrics.first { $0.name == "power" }?.value
        let stableValue = Self.stableSystemPowerWatts(
            fresh: fresh,
            cached: lastKnownSystemPowerWatts,
            previousMetric: previousMetric
        )
        lastKnownSystemPowerWatts = stableValue
        return stableValue
    }

    static func stableSystemPowerWatts(
        fresh: Double?,
        cached: Double?,
        previousMetric: String?
    ) -> Double? {
        validSystemPowerWatts(fresh)
            ?? validSystemPowerWatts(cached)
            ?? systemPowerWatts(from: previousMetric)
    }

    private static func validSystemPowerWatts(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0.05 else {
            return nil
        }
        return value
    }

    private static func systemPowerWatts(from metric: String?) -> Double? {
        guard let metric,
              let value = Double(metric.split(separator: " ").first ?? "") else {
            return nil
        }
        return validSystemPowerWatts(value)
    }

    private func smartBatteryInfo(at date: Date) -> SmartBatteryInfo {
        if let cachedSmartBatteryInfo,
           date.timeIntervalSince(cachedSmartBatteryInfo.refreshedAt) < smartBatteryRefreshInterval {
            return cachedSmartBatteryInfo.value
        }

        let value = readSmartBatteryInfo()
        cachedSmartBatteryInfo = (value, date)
        return value
    }

    private func readSmartBatteryInfo() -> SmartBatteryInfo {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else {
            return SmartBatteryInfo()
        }
        defer { IOObjectRelease(service) }

        let cycleCount = intRegistryValue(service, "CycleCount")
        let designCapacity = doubleRegistryValue(service, "DesignCapacity")
        let maxCapacity = doubleRegistryValue(service, "AppleRawMaxCapacity")
            ?? doubleRegistryValue(service, "MaxCapacity")
        let adapterWatts = adapterWatts(service)
        let chargingPowerWatts = chargingPowerWatts(service)
        let temperature = doubleRegistryValue(service, "Temperature").map { $0 / 100 }
        let health = if let maxCapacity, let designCapacity, designCapacity > 0 {
            min(100, max(0, maxCapacity / designCapacity * 100))
        } else {
            nil as Double?
        }
        return SmartBatteryInfo(
            cycleCount: cycleCount,
            healthPercent: health,
            adapterWatts: adapterWatts,
            chargingPowerWatts: chargingPowerWatts,
            temperatureCelsius: temperature
        )
    }

    private func adapterWatts(_ service: io_service_t) -> Double? {
        guard let value = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return doubleValue(value["Watts"])
    }

    private func externalAdapterWatts() -> Double? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return doubleValue(details[kIOPSPowerAdapterWattsKey])
    }

    private func chargingPowerWatts(_ service: io_service_t) -> Double? {
        if let value = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
           let watts = Self.chargingPowerWatts(
               batteryPowerMilliwatts: signedDoubleValue(value["BatteryPower"])
           ) {
            return watts
        }

        guard let value = IORegistryEntryCreateCFProperty(service, "ChargerData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
              let current = doubleValue(value["ChargingCurrent"]) else {
            return nil
        }
        guard let voltage = doubleRegistryValue(service, "AppleRawBatteryVoltage")
            ?? doubleRegistryValue(service, "Voltage")
            ?? doubleValue(value["ChargingVoltage"]),
              voltage > 0 else {
            return nil
        }
        return max(0, current * voltage / 1_000_000)
    }

    private func powerTelemetry() -> BatteryPowerTelemetry? {
        for _ in 0..<2 {
            if powerTelemetryService == IO_OBJECT_NULL {
                powerTelemetryService = IOServiceGetMatchingService(
                    kIOMainPortDefault,
                    IOServiceMatching("AppleSmartBattery")
                )
            }
            guard powerTelemetryService != IO_OBJECT_NULL else {
                return nil
            }
            if let telemetry = BatteryPowerTelemetryReader.read(service: powerTelemetryService) {
                return telemetry
            }
            IOObjectRelease(powerTelemetryService)
            powerTelemetryService = IO_OBJECT_NULL
        }
        return nil
    }

    static func chargingPowerWatts(batteryPowerMilliwatts: Double?) -> Double? {
        BatteryPowerTelemetry(
            adapterInputMilliwatts: nil,
            systemLoadMilliwatts: nil,
            batteryMilliwatts: batteryPowerMilliwatts
        ).chargingWatts
    }

    static func systemPowerWatts(
        systemLoadMilliwatts: Double?,
        systemPowerInMilliwatts: Double?,
        batteryPowerMilliwatts: Double?
    ) -> Double? {
        BatteryPowerTelemetry(
            adapterInputMilliwatts: systemPowerInMilliwatts,
            systemLoadMilliwatts: systemLoadMilliwatts,
            batteryMilliwatts: batteryPowerMilliwatts
        ).resolvedSystemLoadWatts
    }

    private func intRegistryValue(_ service: io_service_t, _ key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return intValue(value)
    }

    private func doubleRegistryValue(_ service: io_service_t, _ key: String) -> Double? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return doubleValue(value)
    }
}

nonisolated private struct SmartBatteryInfo {
    var cycleCount: Int?
    var healthPercent: Double?
    var adapterWatts: Double?
    var chargingPowerWatts: Double?
    var temperatureCelsius: Double?
}
