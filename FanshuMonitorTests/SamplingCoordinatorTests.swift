import Foundation
import Testing
@testable import FanshuMonitor

struct SamplingCoordinatorTests {
    @Test func cancelledQueuedWorkerDoesNotReadSampler() async throws {
        let sampler = BlockingFakeSampler()
        let worker = MonitorModuleSamplerWorker(kind: .cpu, sampler: sampler)
        let context = MonitorSamplingContext(enabledMetricIDs: ["temperature"], panelVisible: true)
        let first = Task.detached { await worker.sample(previous: nil, context: context) }
        defer { sampler.unblock.signal() }
        for _ in 0..<1000 {
            if sampler.callCount == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(sampler.callCount == 1)
        let queued = Task.detached { await worker.sample(previous: nil, context: context) }
        queued.cancel()
        sampler.unblock.signal()
        _ = await first.value
        #expect(await queued.value == nil)
        #expect(sampler.callCount == 1)
    }

    @Test func codexUsesItsDedicatedSamplingPath() async {
        let coordinator = SamplingCoordinator()

        let module = await coordinator.sampleModule(
            kind: .codex,
            previous: nil,
            enabledMetricIDs: [],
            panelVisible: true
        )

        #expect(module == nil)
    }

    @Test func samplingLoadsAndReleasesRequestedWorker() async {
        let coordinator = SamplingCoordinator()

        let module = await coordinator.sampleModule(
            kind: .memory,
            previous: MonitorModule.placeholder(kind: .memory),
            enabledMetricIDs: Set(MonitorKind.memory.availableMetrics.map(\.id)),
            panelVisible: true
        )

        #expect(module?.kind == .memory)
        #expect(module?.summary != "--")
        let loadedKinds = await coordinator.loadedSamplerKinds()
        #expect(loadedKinds == [.memory])

        await coordinator.retainSamplers(for: [], requestID: 1)

        let releasedKinds = await coordinator.loadedSamplerKinds()
        #expect(releasedKinds.isEmpty)
    }

    @Test func samplingLoadsEveryRequestedWorkerAndNothingElse() async {
        let coordinator = SamplingCoordinator()
        for kind in [MonitorKind.cpu, .memory, .battery] {
            _ = await coordinator.sampleModule(
                kind: kind,
                previous: MonitorModule.placeholder(kind: kind),
                enabledMetricIDs: Set(kind.availableMetrics.map(\.id)),
                panelVisible: false
            )
        }
        let loadedKinds = await coordinator.loadedSamplerKinds()
        #expect(loadedKinds == [.cpu, .memory, .battery])
    }

    @Test func staleResidencyRequestCannotUnloadCurrentWorkers() async {
        let coordinator = SamplingCoordinator()
        _ = await coordinator.sampleModule(
            kind: .cpu,
            previous: MonitorModule.placeholder(kind: .cpu),
            enabledMetricIDs: Set(MonitorKind.cpu.availableMetrics.map(\.id)),
            panelVisible: true
        )

        await coordinator.retainSamplers(for: [.cpu], requestID: 2)
        await coordinator.retainSamplers(for: [], requestID: 1)

        #expect(await coordinator.loadedSamplerKinds() == [.cpu])
    }

    @Test func staleResidencyRequestCannotReleaseCurrentCodexSampler() async throws {
        let authURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(#"{"tokens":{"access_token":"test-token"}}"#.utf8).write(to: authURL)
        defer { try? FileManager.default.removeItem(at: authURL) }
        let client = CodexUsageClient(authFileURL: authURL, transport: { request in
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"rate_limit":{"primary_window":{"used_percent":20}}}"#.utf8), response)
        })
        let coordinator = SamplingCoordinator(codexSampler: CodexQuotaSampler(client: client, saveReport: { _ in }))
        _ = await coordinator.refreshCodex(previous: nil, force: false)

        await coordinator.retainSamplers(for: [.codex], requestID: 2)
        await coordinator.retainSamplers(for: [], requestID: 1)

        #expect(await coordinator.loadedSamplerKinds() == [.codex])
        await coordinator.retainSamplers(for: [], requestID: 3)
        #expect(await coordinator.loadedSamplerKinds().isEmpty)
    }

    @Test func residencyAloneDoesNotCreateCodexSampler() async {
        let coordinator = SamplingCoordinator()

        await coordinator.retainSamplers(for: [.codex], requestID: 1)

        #expect(await coordinator.loadedSamplerKinds().isEmpty)
    }

    @Test func brightnessInterceptionRequiresBothPermissions() {
        #expect(BrightnessKeyEventTap.canInterceptBrightnessKeys(
            accessibilityGranted: true,
            inputMonitoringGranted: true
        ))
        #expect(!BrightnessKeyEventTap.canInterceptBrightnessKeys(
            accessibilityGranted: false,
            inputMonitoringGranted: true
        ))
        #expect(!BrightnessKeyEventTap.canInterceptBrightnessKeys(
            accessibilityGranted: true,
            inputMonitoringGranted: false
        ))
    }
}

nonisolated private final class BlockingFakeSampler: MonitorSampler, @unchecked Sendable {
    let kind = MonitorKind.cpu
    let unblock = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    func sample(previous: MonitorModule?, context: MonitorSamplingContext) -> MonitorModule {
        lock.withLock { calls += 1 }
        _ = unblock.wait(timeout: .now() + 5)
        return MonitorModule.placeholder(kind: kind)
    }
}
