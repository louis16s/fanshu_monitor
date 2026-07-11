import Foundation
import OSLog

struct SystemMonitorSnapshot: Sendable {
    var modules: [MonitorModule]
}

nonisolated final class SystemMonitorSampler: @unchecked Sendable {
    private var samplers: [MonitorKind: MonitorSampler] = [:]
    private var codexRefreshInterval: TimeInterval = 300

    func sample(previousModules: [MonitorModule]) -> Result<SystemMonitorSnapshot, SamplingError> {
        sample(kinds: MonitorKind.allCases, previousModules: previousModules)
    }

    func sample(kinds: some Sequence<MonitorKind>, previousModules: [MonitorModule]) -> Result<SystemMonitorSnapshot, SamplingError> {
        autoreleasepool {
            var modulesByKind = Dictionary(uniqueKeysWithValues: previousModules.map { ($0.kind, $0) })
            var errors: [SamplingError] = []

            for kind in kinds {
                let sampler = sampler(for: kind)
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
        codexRefreshInterval = min(3600, max(60, interval))
        (samplers[.codex] as? CodexQuotaSampler)?.setRefreshInterval(codexRefreshInterval)
    }

    func releaseSamplers(except visibleKinds: Set<MonitorKind>) {
        samplers = samplers.filter { visibleKinds.contains($0.key) }
    }

    func loadedSamplerKinds() -> Set<MonitorKind> {
        Set(samplers.keys)
    }

    func refreshCodex(previousModules: [MonitorModule], completion: @escaping (SystemMonitorSnapshot) -> Void) {
        let previous = previousModules.first { $0.kind == .codex }
        let codexSampler = sampler(for: .codex) as! CodexQuotaSampler
        codexSampler.forceRefresh(previous: previous) { module in
            var modulesByKind = Dictionary(uniqueKeysWithValues: previousModules.map { ($0.kind, $0) })
            modulesByKind[.codex] = module
            let modules = MonitorKind.allCases.map { kind in
                modulesByKind[kind] ?? MonitorModule.placeholder(kind: kind)
            }
            completion(SystemMonitorSnapshot(modules: modules))
        }
    }

    private func sampler(for kind: MonitorKind) -> MonitorSampler {
        if let sampler = samplers[kind] {
            return sampler
        }

        let sampler: MonitorSampler
        switch kind {
        case .cpu:
            sampler = CPUSampler()
        case .gpu:
            sampler = GPUSampler()
        case .memory:
            sampler = MemorySampler()
        case .storage:
            sampler = StorageSampler()
        case .network:
            sampler = NetworkSampler()
        case .battery:
            sampler = BatterySampler()
        case .codex:
            let codexSampler = CodexQuotaSampler()
            codexSampler.setRefreshInterval(codexRefreshInterval)
            sampler = codexSampler
        }
        samplers[kind] = sampler
        AppLogger.sampler.debug("Loaded sampler for \(kind.rawValue, privacy: .public)")
        return sampler
    }
}
