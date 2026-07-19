import Foundation

nonisolated protocol MonitorSampler {
    var kind: MonitorKind { get }
    func sample(previous: MonitorModule?) -> MonitorModule
}
