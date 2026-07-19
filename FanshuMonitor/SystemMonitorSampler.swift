import Foundation
import OSLog

nonisolated struct SystemMonitorSnapshot: Sendable {
    var modules: [MonitorModule]
}

nonisolated final class SystemMonitorSampler: @unchecked Sendable {
    private var samplers: [MonitorKind: MonitorSampler] = [:]

    func sample(previousModules: [MonitorModule]) -> SystemMonitorSnapshot {
        sample(kinds: MonitorKind.allCases, previousModules: previousModules)
    }

    func sample(kinds: some Sequence<MonitorKind>, previousModules: [MonitorModule]) -> SystemMonitorSnapshot {
        autoreleasepool {
            var modulesByKind = Dictionary(uniqueKeysWithValues: previousModules.map { ($0.kind, $0) })

            for kind in kinds where kind != .codex {
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

            return SystemMonitorSnapshot(modules: modules)
        }
    }

    func releaseSamplers(except visibleKinds: Set<MonitorKind>) {
        samplers = samplers.filter { visibleKinds.contains($0.key) }
    }

    func loadedSamplerKinds() -> Set<MonitorKind> {
        Set(samplers.keys)
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
            preconditionFailure("Codex sampling is owned by SamplingCoordinator")
        }
        samplers[kind] = sampler
        AppLogger.sampler.debug("Loaded sampler for \(kind.rawValue, privacy: .public)")
        return sampler
    }
}
