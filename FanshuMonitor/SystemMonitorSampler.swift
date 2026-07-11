import Foundation
import OSLog

struct SystemMonitorSnapshot: Sendable {
    var modules: [MonitorModule]
}

nonisolated final class SystemMonitorSampler: @unchecked Sendable {
    private let codexSampler = CodexQuotaSampler()
    private let samplers: [MonitorKind: MonitorSampler]

    init() {
        samplers = [
            .cpu: CPUSampler(),
            .gpu: GPUSampler(),
            .memory: MemorySampler(),
            .storage: StorageSampler(),
            .network: NetworkSampler(),
            .battery: BatterySampler(),
            .codex: codexSampler
        ]
    }

    func sample(previousModules: [MonitorModule]) -> Result<SystemMonitorSnapshot, SamplingError> {
        sample(kinds: MonitorKind.allCases, previousModules: previousModules)
    }

    func sample(kinds: some Sequence<MonitorKind>, previousModules: [MonitorModule]) -> Result<SystemMonitorSnapshot, SamplingError> {
        autoreleasepool {
            var modulesByKind = Dictionary(uniqueKeysWithValues: previousModules.map { ($0.kind, $0) })
            var errors: [SamplingError] = []

            for kind in kinds {
                guard let sampler = samplers[kind] else {
                    AppLogger.sampler.error("No sampler registered for kind: \(kind.rawValue, privacy: .public)")
                    errors.append(samplingError(for: kind))
                    continue
                }
                let previous = modulesByKind[kind]
                let module = sampler.sample(previous: previous)

                if let previous {
                    var updated = module
                    updated.samples = Array((previous.samples + [module.value]).suffix(MonitorConstants.sparklineMaxPoints))
                    modulesByKind[kind] = updated
                } else {
                    modulesByKind[kind] = module
                }
            }

            let modules = MonitorKind.allCases.map { kind in
                modulesByKind[kind] ?? MonitorModule.placeholder(kind: kind)
            }

            if errors.isEmpty {
                return .success(SystemMonitorSnapshot(modules: modules))
            } else if modulesByKind.isEmpty {
                return .failure(errors[0])
            } else {
                // Partial success: some modules sampled, some failed
                AppLogger.sampler.error("Partial sampling failure: \(errors.map(\.description).joined(separator: ", "), privacy: .public)")
                return .success(SystemMonitorSnapshot(modules: modules))
            }
        }
    }

    func setCodexRefreshInterval(_ interval: TimeInterval) {
        codexSampler.setRefreshInterval(interval)
    }

    func refreshCodex(previousModules: [MonitorModule], completion: @escaping (SystemMonitorSnapshot) -> Void) {
        let previous = previousModules.first { $0.kind == .codex }
        codexSampler.forceRefresh(previous: previous) { module in
            var modulesByKind = Dictionary(uniqueKeysWithValues: previousModules.map { ($0.kind, $0) })
            modulesByKind[.codex] = module
            let modules = MonitorKind.allCases.map { kind in
                modulesByKind[kind] ?? MonitorModule.placeholder(kind: kind)
            }
            completion(SystemMonitorSnapshot(modules: modules))
        }
    }

    private func samplingError(for kind: MonitorKind) -> SamplingError {
        switch kind {
        case .cpu: return .cpuUnavailable
        case .gpu: return .gpuUnavailable
        case .memory: return .memoryUnavailable
        case .storage: return .storageUnavailable
        case .network: return .networkUnavailable
        case .battery: return .batteryUnavailable
        case .codex: return .codexUnavailable
        }
    }
}
