import Foundation

/// Owns module workers away from the main actor and lets independent modules
/// sample concurrently.
actor SamplingCoordinator {
    private var workers: [MonitorKind: MonitorModuleSamplerWorker] = [:]
    private var codexSampler: CodexQuotaSampler?
    private var codexRefreshInterval: TimeInterval = 300
    private var latestResidencyRequestID: UInt64 = 0

    func setCodexRefreshInterval(_ interval: TimeInterval) async {
        codexRefreshInterval = min(3600, max(60, interval))
        if let codexSampler {
            await codexSampler.setRefreshInterval(codexRefreshInterval)
        }
    }

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
