import Foundation

nonisolated struct MonitorSamplingContext: Sendable, Equatable {
    let enabledMetricIDs: Set<String>
    let panelVisible: Bool

    func includes(_ metricID: String) -> Bool {
        enabledMetricIDs.contains(metricID)
    }

    func shouldCollectExpensiveMetric(_ metricID: String) -> Bool {
        panelVisible && includes(metricID)
    }
}

nonisolated protocol MonitorSampler {
    var kind: MonitorKind { get }
    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule
}
