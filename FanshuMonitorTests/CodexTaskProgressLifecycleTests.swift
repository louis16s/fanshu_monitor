import Foundation
import Testing
@testable import FanshuMonitor

private actor DeferredCodexTaskProgressLoader {
    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<[CodexTaskProgress], Never>] = [:]

    func load() async -> [CodexTaskProgress] {
        nextRequestID += 1
        let requestID = nextRequestID
        return await withCheckedContinuation { pending[requestID] = $0 }
    }

    func resolve(_ requestID: Int, with result: [CodexTaskProgress]) {
        pending.removeValue(forKey: requestID)?.resume(returning: result)
    }

    func requestCount() -> Int { nextRequestID }
}

@MainActor
@Suite(.serialized)
struct CodexTaskProgressLifecycleTests {
    @Test func staleReadCannotReleaseTheCurrentRequestSlot() async throws {
        let suite = "CodexTaskProgressLifecycleTests.staleReadCannotReleaseTheCurrentRequestSlot"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = MonitorSettings(defaults: defaults)
        settings.setVisible(true, for: .codex)
        settings.setMetric(.activeTasks, enabled: true, for: .codex)
        #expect(settings.isVisible(.codex))
        #expect(settings.isMetricEnabled(.activeTasks, for: .codex))
        let loader = DeferredCodexTaskProgressLoader()
        let store = MonitorStore(
            settings: settings,
            codexTaskProgressLoader: { await loader.load() }
        )
        store.isPanelVisible = true
        #expect(store.isPanelVisible)

        store.configureCodexTaskProgressMonitoring()
        await waitForRequest(1, loader: loader)
        store.configureCodexTaskProgressMonitoring()
        await waitForRequest(2, loader: loader)
        let countAfterRestart = await loader.requestCount()
        #expect(countAfterRestart == 2)

        await loader.resolve(1, with: [task(id: "stale")])
        try await Task.sleep(for: .milliseconds(20))
        store.refreshCodexTaskProgress()
        let countWithCurrentRequestPending = await loader.requestCount()
        #expect(countWithCurrentRequestPending == 2)

        await loader.resolve(2, with: [task(id: "current")])
        for _ in 0..<100 where store.codexTasks.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.codexTasks.map(\.id) == ["current"])

        store.isPanelVisible = false
        store.configureCodexTaskProgressMonitoring()
    }

    private func waitForRequest(_ requestID: Int, loader: DeferredCodexTaskProgressLoader) async {
        for _ in 0..<100 {
            if await loader.requestCount() >= requestID { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func task(id: String) -> CodexTaskProgress {
        CodexTaskProgress(id: id, title: id, completedSteps: 0, totalSteps: 0, activeStep: nil)
    }
}
