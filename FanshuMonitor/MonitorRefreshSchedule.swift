import Foundation

final class MonitorRefreshSchedule {
    let tickInterval: TimeInterval

    private let intervals: [MonitorKind: TimeInterval]
    private var lastRefreshDates: [MonitorKind: Date] = [:]

    init(
        tickInterval: TimeInterval = 1,
        intervals: [MonitorKind: TimeInterval] = [
            .cpu: 1, .gpu: 2, .memory: 3,
            .storage: 10, .network: 1, .battery: 5, .codex: 5
        ]
    ) {
        self.tickInterval = tickInterval
        self.intervals = intervals
    }

    func dueKinds(at date: Date, visibleKinds: Set<MonitorKind>? = nil, panelVisible: Bool = true) -> [MonitorKind] {
        let kinds = visibleKinds ?? Set(MonitorKind.allCases)
        let dueKinds = MonitorKind.allCases.filter { kind in
            guard kinds.contains(kind) else { return false }
            let interval = effectiveInterval(for: kind, panelVisible: panelVisible)
            guard let lastRefreshDate = lastRefreshDates[kind] else {
                return true
            }

            return date.timeIntervalSince(lastRefreshDate) >= interval
        }
        markRefreshed(dueKinds, at: date)
        return dueKinds
    }

    func reset() {
        lastRefreshDates.removeAll()
    }

    func markRefreshed(_ kinds: some Sequence<MonitorKind>, at date: Date) {
        for kind in kinds {
            lastRefreshDates[kind] = date
        }
    }

    private func effectiveInterval(for kind: MonitorKind, panelVisible: Bool) -> TimeInterval {
        let base = intervals[kind] ?? tickInterval
        guard !panelVisible else { return base }
        switch kind {
        case .cpu, .memory:
            return max(base, 5)
        case .gpu, .network, .battery:
            return max(base, 15)
        case .codex:
            return max(base, 300)
        case .storage:
            return max(base, 60)
        }
    }
}
