import Foundation
import OSLog

/// Serializes sampler state away from the main actor and drops stale results.
actor SamplingCoordinator {
    private let sampler = SystemMonitorSampler()
    private let codexSampler = CodexQuotaSampler()

    func setCodexRefreshInterval(_ interval: TimeInterval) async {
        await codexSampler.setRefreshInterval(interval)
    }

    func retainSamplers(for visibleKinds: Set<MonitorKind>) async {
        sampler.releaseSamplers(except: visibleKinds)
        if !visibleKinds.contains(.codex) {
            await codexSampler.release()
        }
    }

    func loadedSamplerKinds() -> Set<MonitorKind> {
        sampler.loadedSamplerKinds()
    }

    func sample(
        kinds: [MonitorKind],
        previousModules: [MonitorModule]
    ) -> SystemMonitorSnapshot? {
        guard !kinds.isEmpty else { return nil }
        guard !Task.isCancelled else { return nil }

        let snapshot = sampler.sample(kinds: kinds, previousModules: previousModules)
        guard !Task.isCancelled else { return nil }
        return snapshot
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
}
