import Foundation
import Testing
@testable import FanshuMonitor

struct SamplerReliabilityTests {
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
