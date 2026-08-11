import Foundation

nonisolated enum MonitorSamplingMode: Sendable, Equatable {
    case routine
    case firstPaint
}

nonisolated struct MonitorSamplingContext: Sendable, Equatable {
    let enabledMetricIDs: Set<String>
    let panelVisible: Bool
    let mode: MonitorSamplingMode

    init(
        enabledMetricIDs: Set<String>,
        panelVisible: Bool,
        mode: MonitorSamplingMode = .routine
    ) {
        self.enabledMetricIDs = enabledMetricIDs
        self.panelVisible = panelVisible
        self.mode = mode
    }

    func includes(_ metricID: String) -> Bool {
        enabledMetricIDs.contains(metricID)
    }

    func shouldCollectExpensiveMetric(_ metricID: String) -> Bool {
        panelVisible && includes(metricID)
    }

    var prioritizesFirstPaint: Bool {
        panelVisible && mode == .firstPaint
    }
}

nonisolated protocol MonitorSampler {
    var kind: MonitorKind { get }
    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule
}
