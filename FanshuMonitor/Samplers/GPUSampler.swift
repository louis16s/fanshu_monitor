import Darwin
import Foundation
import IOKit
import OSLog

nonisolated final class GPUSampler: MonitorSampler {
    var kind: MonitorKind { .gpu }
    private lazy var smcReader = SMCReader()

    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule {
        guard let reading = gpuReading() else {
            AppLogger.sampler.error("gpuReading() returned nil, GPU data unavailable")
            return previous ?? MonitorModule.placeholder(kind: .gpu)
        }

        let utilization = min(100, max(0, reading.utilization))
        var metrics = [
            MonitorMetric(
                name: "gpu-memory",
                value: retainedMetric(
                    "gpu-memory",
                    freshValue: reading.usedMemory.map(bytes),
                    previous: previous,
                    initialValue: "0 B"
                )
            ),
            MonitorMetric(
                name: "allocated",
                value: retainedMetric(
                    "allocated",
                    freshValue: reading.allocatedMemory.map(bytes),
                    previous: previous,
                    initialValue: "0 B"
                )
            )
        ]

        metrics.append(MonitorMetric(
            name: "render",
            value: retainedMetric(
                "render",
                freshValue: reading.renderUtilization.map(percent),
                previous: previous,
                initialValue: "0%"
            )
        ))

        if context.includes("temperature") {
            let temperature = context.shouldCollectExpensiveMetric("temperature")
                ? gpuTemperatureText()
                : previous?.metrics.first { $0.name == "temperature" }?.value
            metrics.append(MonitorMetric(name: "temperature", value: temperature ?? "--"))
        }

        if context.includes("tiler") {
            metrics.append(MonitorMetric(
                name: "tiler",
                value: retainedMetric(
                    "tiler",
                    freshValue: reading.tilerUtilization.map(percent),
                    previous: previous,
                    initialValue: "0%"
                )
            ))
        }

        return MonitorModule(
            kind: .gpu,
            value: utilization,
            summary: percent(utilization),
            metrics: metrics,
            samples: seedSamples(utilization)
        )
    }

    private func gpuReading() -> GPUReading? {
        let accelerators = acceleratorServices()
        guard !accelerators.isEmpty else {
            AppLogger.sampler.error("No IOAccelerator services found")
            return nil
        }
        defer {
            accelerators.forEach { IOObjectRelease($0) }
        }

        var best: GPUReading?
        for accelerator in accelerators {
            guard let stats = registryDictionaryValue(accelerator, "PerformanceStatistics") else {
                AppLogger.sampler.error("Failed to read PerformanceStatistics from IOAccelerator service")
                continue
            }

            let utilization = doubleValue(stats["Device Utilization %"])
                ?? doubleValue(stats["GPU Activity(%)"])
                ?? 0
            let render = doubleValue(stats["Renderer Utilization %"])
            let tiler = doubleValue(stats["Tiler Utilization %"])
            let usedMemory = doubleValue(stats["In use system memory"])
            let allocatedMemory = doubleValue(stats["Alloc system memory"])
            let reading = GPUReading(
                utilization: utilization,
                renderUtilization: render,
                tilerUtilization: tiler,
                usedMemory: usedMemory,
                allocatedMemory: allocatedMemory
            )

            if best == nil || reading.utilization > (best?.utilization ?? 0) {
                best = reading
            }
        }

        return best
    }

    private func acceleratorServices() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard result == KERN_SUCCESS else {
            AppLogger.sampler.error("IOServiceGetMatchingServices for IOAccelerator failed with result: \(result)")
            return []
        }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else {
                break
            }
            services.append(service)
        }
        return services
    }

    private func gpuTemperatureText() -> String? {
        smcReader?.gpuTemperature().map { "\(String(format: "%.0f", $0))°C" }
    }

    private func retainedMetric(
        _ name: MetricID,
        freshValue: String?,
        previous: MonitorModule?,
        initialValue: String
    ) -> String {
        freshValue
            ?? previous?.metrics.first { $0.name == name }?.value
            ?? initialValue
    }
}

nonisolated private struct GPUReading {
    let utilization: Double
    let renderUtilization: Double?
    let tilerUtilization: Double?
    let usedMemory: Double?
    let allocatedMemory: Double?
}
