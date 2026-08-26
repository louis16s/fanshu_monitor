import Foundation

nonisolated struct MonitorSamplingContext: Sendable, Equatable {
    let enabledMetricIDs: Set<MetricID>
    let panelVisible: Bool

    init(
        enabledMetricIDs: Set<MetricID>,
        panelVisible: Bool
    ) {
        self.enabledMetricIDs = enabledMetricIDs
        self.panelVisible = panelVisible
    }

    func includes(_ metricID: MetricID) -> Bool {
        enabledMetricIDs.contains(metricID)
    }

    func shouldCollectExpensiveMetric(_ metricID: MetricID) -> Bool {
        panelVisible && includes(metricID)
    }

}

nonisolated protocol MonitorSampler {
    var kind: MonitorKind { get }
    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule
}
