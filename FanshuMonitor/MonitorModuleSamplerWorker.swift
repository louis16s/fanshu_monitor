import Foundation
import OSLog

/// Owns one stateful sampler. Calls for the same module stay serialized while
/// different module workers can run concurrently.
actor MonitorModuleSamplerWorker {
    let kind: MonitorKind
    private let sampler: MonitorSampler

    init(kind: MonitorKind) {
        self.kind = kind
        sampler = Self.makeSampler(for: kind)
        AppLogger.sampler.debug("Loaded sampler for \(kind.rawValue, privacy: .public)")
    }

    func sample(
        previous: MonitorModule?,
        context: MonitorSamplingContext
    ) -> MonitorModule {
        autoreleasepool {
            var module = sampler.sample(previous: previous, context: context)
            if let previous {
                module.samples = Array(
                    (previous.samples + [module.value])
                        .suffix(MonitorConstants.sparklineMaxPoints)
                )
            }
            return module
        }
    }

    private static func makeSampler(for kind: MonitorKind) -> MonitorSampler {
        switch kind {
        case .cpu:
            CPUSampler()
        case .gpu:
            GPUSampler()
        case .memory:
            MemorySampler()
        case .network:
            NetworkSampler()
        case .battery:
            BatterySampler()
        case .codex:
            preconditionFailure("Codex sampling is owned by SamplingCoordinator")
        }
    }
}
