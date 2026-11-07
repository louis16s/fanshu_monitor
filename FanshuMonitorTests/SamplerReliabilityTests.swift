import Foundation
import Testing
@testable import FanshuMonitor

struct SamplerReliabilityTests {
    @Test func samplerFailureLogsAreRateLimitedAndRecoverAfterTheInterval() {
        var throttle = SamplerFailureLogThrottle(minimumInterval: 60)
        let start = Date(timeIntervalSince1970: 1_000)

        let first = throttle.shouldLog(at: start)
        let early = throttle.shouldLog(at: start.addingTimeInterval(59.9))
        let boundary = throttle.shouldLog(at: start.addingTimeInterval(60))
        let clockMovedBack = throttle.shouldLog(at: start.addingTimeInterval(30))
        let nextBoundary = throttle.shouldLog(at: start.addingTimeInterval(120))

        #expect(first)
        #expect(!early)
        #expect(boundary)
        #expect(!clockMovedBack)
        #expect(nextBoundary)
    }

    @Test func temperaturesRetainPreviousOnInvalidRead() {
        var previous = MonitorModule.placeholder(kind: .cpu)
        previous.metrics = [MonitorMetric(name: "temperature", value: "55°C")]
        for value: Double? in [nil, 0, .nan, .infinity] {
            #expect(CPUSampler.temperatureText(value, previous: previous) == "55°C")
        }
        #expect(CPUSampler.temperatureText(60, previous: previous) == "60°C")
        #expect(CPUSampler.temperatureText(nil, previous: nil) == "--")
        previous.metrics = [MonitorMetric(name: "temperature", value: "0°C")]
        #expect(CPUSampler.temperatureText(nil, previous: previous) == "--")
    }

    @Test func gpuMissingDetailsAreUnknownAndZeroRemainsReal() {
        let context = MonitorSamplingContext(enabledMetricIDs: ["temperature", "tiler"], panelVisible: true)
        var previous = MonitorModule.placeholder(kind: .gpu)
        previous.metrics = [MonitorMetric(name: "temperature", value: "55°C")]
        let missing = GPUSampler(readGPU: {
            GPUReading(utilization: 10, renderUtilization: nil, tilerUtilization: nil, usedMemory: nil, allocatedMemory: nil)
        }, readTemperature: { nil }).sample(previous: previous, context: context)
        #expect(missing.summary == "10%")
        #expect(missing.metrics.first { $0.name == "temperature" }?.value == "55°C")
        for id: MetricID in ["gpu-memory", "allocated", "render", "tiler"] {
            #expect(missing.metrics.first { $0.name == id }?.value == "--")
        }
        let zero = GPUSampler(readGPU: {
            GPUReading(utilization: 0, renderUtilization: 0, tilerUtilization: 0, usedMemory: 0, allocatedMemory: 0)
        }, readTemperature: { 60 }).sample(previous: missing, context: context)
        #expect(zero.metrics.first { $0.name == "render" }?.value == "0%")
        #expect(zero.metrics.first { $0.name == "temperature" }?.value == "60°C")
        let placeholder = GPUSampler(readGPU: {
            GPUReading(utilization: 10, renderUtilization: nil, tilerUtilization: nil, usedMemory: nil, allocatedMemory: nil)
        }, readTemperature: { nil }).sample(previous: .placeholder(kind: .gpu), context: context)
        #expect(placeholder.summary == "10%")
        #expect(placeholder.metrics.first { $0.name == "render" }?.value == "--")
        var reading = GPUReading(utilization: 0, renderUtilization: 0, tilerUtilization: 0, usedMemory: 0, allocatedMemory: 0)
        let sampler = GPUSampler(readGPU: { reading }, readTemperature: { nil })
        let realZero = sampler.sample(previous: nil, context: context)
        reading = GPUReading(utilization: 10, renderUtilization: nil, tilerUtilization: nil, usedMemory: nil, allocatedMemory: nil)
        let retained = sampler.sample(previous: realZero, context: context)
        #expect(retained.metrics.first { $0.name == "render" }?.value == "0%")
        let recreated = GPUSampler(readGPU: { reading }, readTemperature: { nil })
            .sample(previous: realZero, context: context)
        #expect(recreated.metrics.first { $0.name == "render" }?.value == "0%")
    }

    @Test func gpuNonFiniteDetailsRetainLastValidValuesWithoutFormattingCrashes() {
        let context = MonitorSamplingContext(enabledMetricIDs: ["temperature", "tiler"], panelVisible: true)
        var reading = GPUReading(
            utilization: 50,
            renderUtilization: 24,
            tilerUtilization: 12,
            usedMemory: 1_024,
            allocatedMemory: 4_096
        )
        let sampler = GPUSampler(readGPU: { reading }, readTemperature: { nil })
        let valid = sampler.sample(previous: nil, context: context)
        let validMemory = valid.metrics.first { $0.name == "gpu-memory" }?.value
        let validAllocated = valid.metrics.first { $0.name == "allocated" }?.value
        reading = GPUReading(
            utilization: 55,
            renderUtilization: .nan,
            tilerUtilization: .infinity,
            usedMemory: .nan,
            allocatedMemory: -.infinity
        )

        let afterInvalidDetails = sampler.sample(previous: valid, context: context)
        #expect(afterInvalidDetails.summary == "55%")
        #expect(afterInvalidDetails.metrics.first { $0.name == "render" }?.value == "24%")
        #expect(afterInvalidDetails.metrics.first { $0.name == "tiler" }?.value == "12%")
        #expect(afterInvalidDetails.metrics.first { $0.name == "gpu-memory" }?.value == validMemory)
        #expect(afterInvalidDetails.metrics.first { $0.name == "allocated" }?.value == validAllocated)
        #expect(GPUSampler.percentText(140) == "100%")
        #expect(GPUSampler.percentText(-10) == "0%")
        #expect(GPUSampler.bytesText(Double.nan) == nil)
        #expect(GPUSampler.bytesText(Double(Int64.max)) == nil)
    }

    @Test func gpuRejectsNonFinitePrimaryUtilizationAndKeepsPreviousModule() {
        let context = MonitorSamplingContext(enabledMetricIDs: [], panelVisible: true)
        let previous = MonitorModule(
            kind: .gpu,
            value: 37,
            summary: "37%",
            metrics: [],
            samples: [37]
        )
        let sampler = GPUSampler(
            readGPU: {
                GPUReading(
                    utilization: .nan,
                    renderUtilization: 0,
                    tilerUtilization: 0,
                    usedMemory: 0,
                    allocatedMemory: 0
                )
            },
            readTemperature: { nil }
        )

        #expect(sampler.sample(previous: previous, context: context) == previous)
    }

    @Test func smcRetriesFailedConnectionButKeepsUnsupportedKeys() {
        var date = Date(timeIntervalSince1970: 1000)
        var attempts = 0
        let source = FakeTemperatureSource()
        let cache = SMCTemperatureCache(makeSource: {
            attempts += 1
            return attempts == 1 ? nil : source
        }, now: { date })
        #expect(cache.temperature(gpu: false) == nil)
        #expect(cache.temperature(gpu: false) == nil)
        #expect(attempts == 1)
        date.addTimeInterval(15)
        #expect(cache.temperature(gpu: false) == 55)
        source.value = nil
        #expect(cache.temperature(gpu: false) == nil)
        #expect(cache.temperature(gpu: false) == nil)
        #expect(attempts == 2)
        source.isConnectionValid = false
        #expect(cache.temperature(gpu: false) == nil)
        #expect(cache.temperature(gpu: false) == nil)
        #expect(attempts == 2)
        date.addTimeInterval(15)
        source.isConnectionValid = true
        source.value = 60
        #expect(cache.temperature(gpu: true) == 60)
        #expect(attempts == 3)
    }
}

nonisolated private final class FakeTemperatureSource: SMCTemperatureSource {
    var isConnectionValid = true
    var value: Double? = 55
    func cpuTemperature() -> Double? { value }
    func gpuTemperature() -> Double? { value }
}
