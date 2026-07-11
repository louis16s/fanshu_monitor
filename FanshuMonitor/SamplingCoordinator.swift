import Foundation
import OSLog

/// Serializes sampler state away from the main actor and drops stale results.
actor SamplingCoordinator {
    private let sampler = SystemMonitorSampler()

    func setCodexRefreshInterval(_ interval: TimeInterval) {
        sampler.setCodexRefreshInterval(interval)
    }

    func retainSamplers(for visibleKinds: Set<MonitorKind>) {
        sampler.releaseSamplers(except: visibleKinds)
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

        let result = sampler.sample(kinds: kinds, previousModules: previousModules)
        guard !Task.isCancelled else { return nil }

        switch result {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            AppLogger.sampler.error("Sampling failed: \(error.description, privacy: .public)")
            return nil
        }
    }

    func refreshCodex(previousModules: [MonitorModule]) async -> SystemMonitorSnapshot? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            sampler.refreshCodex(previousModules: previousModules) { snapshot in
                continuation.resume(returning: snapshot)
            }
        }
    }
}
