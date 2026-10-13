import Darwin
import Foundation
import IOKit
import OSLog

nonisolated final class GPUSampler: MonitorSampler {
    var kind: MonitorKind { .gpu }
    private let temperatures = SMCTemperatureCache()
    private let readGPU: (() -> GPUReading?)?
    private let readTemperature: (() -> Double?)?
    private var lastKnownDetails: [MetricID: String] = [:]

    init(readGPU: (() -> GPUReading?)? = nil, readTemperature: (() -> Double?)? = nil) {
        self.readGPU = readGPU
        self.readTemperature = readTemperature
    }
    private var lastUnavailableLogDate: Date?

    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule {
        guard let reading = (readGPU != nil ? readGPU?() : gpuReading()) else {
            logUnavailable("gpuReading() returned nil, GPU data unavailable")
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
                    initialValue: "--"
                )
            ),
            MonitorMetric(
                name: "allocated",
                value: retainedMetric(
                    "allocated",
                    freshValue: reading.allocatedMemory.map(bytes),
                    previous: previous,
                    initialValue: "--"
                )
            )
        ]

        metrics.append(MonitorMetric(
            name: "render",
            value: retainedMetric(
                "render",
                freshValue: reading.renderUtilization.map(percent),
                previous: previous,
                initialValue: "--"
            )
        ))

        if context.includes("temperature") {
            let temperature = context.shouldCollectExpensiveMetric("temperature")
                ? CPUSampler.temperatureText(readTemperature != nil ? readTemperature?() : temperatures.temperature(gpu: true), previous: previous)
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
                    initialValue: "--"
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
            logUnavailable("No IOAccelerator services found")
            return nil
        }
        defer {
            accelerators.forEach { IOObjectRelease($0) }
        }

        var best: GPUReading?
        for accelerator in accelerators {
            guard let stats = registryDictionaryValue(accelerator, "PerformanceStatistics") else {
                logUnavailable("Failed to read PerformanceStatistics from IOAccelerator service")
                continue
            }

            guard let utilization = doubleValue(stats["Device Utilization %"])
                ?? doubleValue(stats["GPU Activity(%)"]),
                  utilization.isFinite else { continue }
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

    private func logUnavailable(_ message: String) {
        let now = Date()
        guard lastUnavailableLogDate.map({ now.timeIntervalSince($0) >= 60 }) ?? true else {
            return
        }
        lastUnavailableLogDate = now
        AppLogger.sampler.error("\(message, privacy: .public)")
    }

    private func acceleratorServices() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard result == KERN_SUCCESS else {
            logUnavailable("IOServiceGetMatchingServices for IOAccelerator failed with result: \(result)")
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

    private func retainedMetric(
        _ name: MetricID,
        freshValue: String?,
        previous: MonitorModule?,
        initialValue: String
    ) -> String {
        if let freshValue {
            lastKnownDetails[name] = freshValue
        }
        if let cached = lastKnownDetails[name] { return cached }
        if let prior = previous?.metrics.first(where: { $0.name == name })?.value,
           !prior.isEmpty, prior != "--" {
            lastKnownDetails[name] = prior
            return prior
        }
        return initialValue
    }
}

nonisolated struct GPUReading {
    let utilization: Double
    let renderUtilization: Double?
    let tilerUtilization: Double?
    let usedMemory: Double?
    let allocatedMemory: Double?
}
