import Foundation
import OSLog

nonisolated struct SystemMonitorSnapshot: Sendable {
    var modules: [MonitorModule]
}

/// Owns module workers away from the main actor and lets independent modules
/// sample concurrently.
actor SamplingCoordinator {
    private var workers: [MonitorKind: MonitorModuleSamplerWorker] = [:]
    private var codexSampler: CodexQuotaSampler?
    private var codexRefreshInterval: TimeInterval = 300
    private var samplerResidencyGeneration: UInt64 = 0

    func setCodexRefreshInterval(_ interval: TimeInterval) async {
        codexRefreshInterval = min(3600, max(60, interval))
        if let codexSampler {
            await codexSampler.setRefreshInterval(codexRefreshInterval)
        }
    }

    func retainSamplers(for visibleKinds: Set<MonitorKind>) async {
        samplerResidencyGeneration &+= 1
        let generation = samplerResidencyGeneration
        workers = workers.filter { visibleKinds.contains($0.key) }
        if !visibleKinds.contains(.codex), let codexSampler {
            await codexSampler.release()
            self.codexSampler = nil
        }
        guard generation == samplerResidencyGeneration else { return }
    }

    func loadedSamplerKinds() -> Set<MonitorKind> {
        var kinds = Set(workers.keys)
        if codexSampler != nil {
            kinds.insert(.codex)
        }
        return kinds
    }

    func sampleModule(
        kind: MonitorKind,
        previous: MonitorModule?,
        enabledMetricIDs: Set<MetricID>,
        panelVisible: Bool
    ) async -> MonitorModule? {
        guard kind != .codex, !Task.isCancelled else { return nil }
        let worker = worker(for: kind)
        let context = MonitorSamplingContext(
            enabledMetricIDs: enabledMetricIDs,
            panelVisible: panelVisible
        )
        let module = await worker.sample(previous: previous, context: context)
        return Task.isCancelled ? nil : module
    }

    func sample(
        kinds: [MonitorKind],
        previousModules: [MonitorModule],
        enabledMetrics: [MonitorKind: Set<MetricID>] = [:],
        panelVisible: Bool = true
    ) async -> SystemMonitorSnapshot? {
        guard !kinds.isEmpty else { return nil }
        guard !Task.isCancelled else { return nil }

        let requestedKinds = Set(kinds).subtracting([.codex])
        let requests = requestedKinds.map { kind in
            (
                kind: kind,
                worker: worker(for: kind),
                previous: previousModules.first { $0.kind == kind },
                metricIDs: enabledMetrics[kind]
                    ?? Set(kind.availableMetrics.filter(\.isDefault).map(\.id))
            )
        }

        let sampledModules = await withTaskGroup(
            of: MonitorModule?.self,
            returning: [MonitorModule].self
        ) { group in
            for request in requests {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let context = MonitorSamplingContext(
                        enabledMetricIDs: request.metricIDs,
                        panelVisible: panelVisible
                    )
                    return await request.worker.sample(
                        previous: request.previous,
                        context: context
                    )
                }
            }

            var modules: [MonitorModule] = []
            for await module in group {
                if let module {
                    modules.append(module)
                }
            }
            return modules
        }
        guard !Task.isCancelled else { return nil }

        var modulesByKind = Dictionary(
            uniqueKeysWithValues: previousModules.map { ($0.kind, $0) }
        )
        for module in sampledModules {
            modulesByKind[module.kind] = module
        }
        return SystemMonitorSnapshot(modules: MonitorKind.allCases.map { kind in
            modulesByKind[kind] ?? MonitorModule.placeholder(kind: kind)
        })
    }

    func refreshCodex(
        previousModules: [MonitorModule],
        force: Bool
    ) async -> MonitorModule? {
        guard !Task.isCancelled else { return nil }
        let previous = previousModules.first { $0.kind == .codex }
        let codexSampler = await activeCodexSampler()
        let module = await codexSampler.sample(previous: previous, force: force)
        guard !Task.isCancelled else { return nil }
        return module
    }

    private func worker(for kind: MonitorKind) -> MonitorModuleSamplerWorker {
        if let worker = workers[kind] {
            return worker
        }
        let worker = MonitorModuleSamplerWorker(kind: kind)
        workers[kind] = worker
        return worker
    }

    private func activeCodexSampler() async -> CodexQuotaSampler {
        if let codexSampler {
            return codexSampler
        }
        let sampler = CodexQuotaSampler()
        await sampler.setRefreshInterval(codexRefreshInterval)
        codexSampler = sampler
        return sampler
    }
}
