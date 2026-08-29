import Testing
@testable import FanshuMonitor

struct SamplingCoordinatorTests {
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

    @Test func staleResidencyRequestCannotReleaseCurrentCodexSampler() async {
        let coordinator = SamplingCoordinator()
        _ = await coordinator.refreshCodex(previousModules: [], force: false)

        await coordinator.retainSamplers(for: [.codex], requestID: 2)
        await coordinator.retainSamplers(for: [], requestID: 1)

        #expect(await coordinator.loadedSamplerKinds() == [.codex])
        await coordinator.retainSamplers(for: [], requestID: 3)
        #expect(await coordinator.loadedSamplerKinds().isEmpty)
    }

    @Test func codexSamplerIsNotCreatedByConfigurationAlone() async {
        let coordinator = SamplingCoordinator()

        await coordinator.setCodexRefreshInterval(600)

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
