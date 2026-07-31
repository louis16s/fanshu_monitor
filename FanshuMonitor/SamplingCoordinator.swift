import Foundation
import OSLog

nonisolated struct SystemMonitorSnapshot: Sendable {
    var modules: [MonitorModule]
}

/// Owns module workers away from the main actor and lets independent modules
/// sample concurrently.
actor SamplingCoordinator {
    private var workers: [MonitorKind: MonitorModuleSamplerWorker] = [:]
    private let codexSampler = CodexQuotaSampler()

    func setCodexRefreshInterval(_ interval: TimeInterval) async {
        await codexSampler.setRefreshInterval(interval)
    }

    func retainSamplers(for visibleKinds: Set<MonitorKind>) async {
        workers = workers.filter { visibleKinds.contains($0.key) }
        if !visibleKinds.contains(.codex) {
            await codexSampler.release()
        }
    }

    func loadedSamplerKinds() -> Set<MonitorKind> {
        Set(workers.keys)
    }

    func sampleModule(
        kind: MonitorKind,
        previous: MonitorModule?,
        enabledMetricIDs: Set<String>,
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
        enabledMetrics: [MonitorKind: Set<String>] = [:],
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
    ) async -> SystemMonitorSnapshot? {
        guard !Task.isCancelled else { return nil }
        let previous = previousModules.first { $0.kind == .codex }
        let module = await codexSampler.sample(previous: previous, force: force)
        guard !Task.isCancelled else { return nil }

        var modulesByKind = Dictionary(uniqueKeysWithValues: previousModules.map { ($0.kind, $0) })
        modulesByKind[.codex] = module
        return SystemMonitorSnapshot(modules: MonitorKind.allCases.map { kind in
            modulesByKind[kind] ?? MonitorModule.placeholder(kind: kind)
        })
    }

    private func worker(for kind: MonitorKind) -> MonitorModuleSamplerWorker {
        if let worker = workers[kind] {
            return worker
        }
        let worker = MonitorModuleSamplerWorker(kind: kind)
        workers[kind] = worker
        return worker
    }
}
