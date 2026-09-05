import Foundation

/// Owns module workers away from the main actor and lets independent modules
/// sample concurrently.
actor SamplingCoordinator {
    private var workers: [MonitorKind: MonitorModuleSamplerWorker] = [:]
    private var codexSampler: CodexQuotaSampler?
    private var latestResidencyRequestID: UInt64 = 0

    func retainSamplers(
        for visibleKinds: Set<MonitorKind>,
        requestID: UInt64
    ) async {
        guard requestID >= latestResidencyRequestID else { return }
        latestResidencyRequestID = requestID
        workers = workers.filter { visibleKinds.contains($0.key) }
        guard !visibleKinds.contains(.codex), let sampler = codexSampler else { return }

        // Detach before awaiting so a newer request can safely create a new sampler.
        codexSampler = nil
        await sampler.release()
    }

    #if DEBUG
    func loadedSamplerKinds() -> Set<MonitorKind> {
        var kinds = Set(workers.keys)
        if codexSampler != nil {
            kinds.insert(.codex)
        }
        return kinds
    }
    #endif

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

    func refreshCodex(
        previous: MonitorModule?,
        force: Bool,
        refreshInterval: TimeInterval = 300
    ) async -> CodexRefreshResult? {
        guard !Task.isCancelled else { return nil }
        let codexSampler = activeCodexSampler()
        let module = await codexSampler.sample(
            previous: previous, force: force, refreshInterval: refreshInterval
        )
        guard !Task.isCancelled else { return nil }
        return CodexRefreshResult(
            module: module,
            scheduledResetRefreshDate: await codexSampler.scheduledResetRefreshDate()
        )
    }

    private func worker(for kind: MonitorKind) -> MonitorModuleSamplerWorker {
        if let worker = workers[kind] {
            return worker
        }
        let worker = MonitorModuleSamplerWorker(kind: kind)
        workers[kind] = worker
        return worker
    }

    private func activeCodexSampler() -> CodexQuotaSampler {
        if let codexSampler {
            return codexSampler
        }
        let sampler = CodexQuotaSampler()
        codexSampler = sampler
        return sampler
    }
}

nonisolated struct CodexRefreshResult: Sendable {
    let module: MonitorModule
    let scheduledResetRefreshDate: Date?
}
