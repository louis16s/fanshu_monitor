import Darwin
import Foundation
import OSLog
import IOKit

nonisolated final class CPUSampler: MonitorSampler {
    var kind: MonitorKind { .cpu }

    private var previousCPUInfo: host_cpu_load_info?
    private lazy var smcReader: SMCReader? = SMCReader()

    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule {
        let info = hostCPULoadInfo()
        let metrics: [MonitorMetric]
        let total: Double
        let temperature = context.shouldCollectExpensiveMetric("temperature")
            ? cpuTemperatureText()
            : previous?.metrics.first { $0.name == "temperature" }?.value ?? "--"

        if let info, let previousCPUInfo {
            let userDiff = Double(info.cpu_ticks.0 &- previousCPUInfo.cpu_ticks.0)
            let systemDiff = Double(info.cpu_ticks.1 &- previousCPUInfo.cpu_ticks.1)
            let idleDiff = Double(info.cpu_ticks.2 &- previousCPUInfo.cpu_ticks.2)
            let niceDiff = Double(info.cpu_ticks.3 &- previousCPUInfo.cpu_ticks.3)
            let all = userDiff + systemDiff + idleDiff + niceDiff

            let system = all > 0 ? (systemDiff / all) * 100 : 0
            let user = all > 0 ? ((userDiff + niceDiff) / all) * 100 : 0
            let idle = all > 0 ? (idleDiff / all) * 100 : 100
            total = min(100, max(0, system + user))
            var currentMetrics = [
                MonitorMetric(name: "system", value: percent(system)),
                MonitorMetric(name: "user", value: percent(user)),
                MonitorMetric(name: "idle", value: percent(idle))
            ]
            if context.includes("temperature") {
                currentMetrics.append(MonitorMetric(name: "temperature", value: temperature))
            }
            metrics = currentMetrics
        } else {
            if let info {
                self.previousCPUInfo = info
            }
            return previous ?? MonitorModule.placeholder(kind: .cpu)
        }

        if let info {
            self.previousCPUInfo = info
        }

        return MonitorModule(
            kind: .cpu,
            value: total,
            summary: percent(total),
            metrics: metrics,
            samples: seedSamples(total)
        )
    }

    private func hostCPULoadInfo() -> host_cpu_load_info? {
        let count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var size = count
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else {
            AppLogger.sampler.error("host_statistics failed with result: \(result)")
            return nil
        }
        return info
    }

    private func cpuTemperatureText() -> String {
        smcReader?.cpuTemperature().map { "\(String(format: "%.0f", $0))°C" } ?? "--"
    }
}
