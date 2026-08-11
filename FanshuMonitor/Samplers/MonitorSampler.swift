import Foundation

nonisolated enum MonitorSamplingMode: Sendable, Equatable {
    case routine
    case firstPaint
}

nonisolated struct MonitorSamplingContext: Sendable, Equatable {
    let enabledMetricIDs: Set<MetricID>
    let panelVisible: Bool
    let mode: MonitorSamplingMode

    init(
        enabledMetricIDs: Set<MetricID>,
        panelVisible: Bool,
        mode: MonitorSamplingMode = .routine
    ) {
        self.enabledMetricIDs = enabledMetricIDs
        self.panelVisible = panelVisible
        self.mode = mode
    }

    func includes(_ metricID: MetricID) -> Bool {
        enabledMetricIDs.contains(metricID)
    }

    func shouldCollectExpensiveMetric(_ metricID: MetricID) -> Bool {
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
