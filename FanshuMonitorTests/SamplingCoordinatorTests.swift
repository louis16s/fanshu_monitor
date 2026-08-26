import Testing
@testable import FanshuMonitor

struct SamplingCoordinatorTests {
    @Test func ignoresEmptySamplingRequests() async {
        let coordinator = SamplingCoordinator()

        let snapshot = await coordinator.sample(kinds: [], previousModules: [])

        #expect(snapshot == nil)
    }

    @Test func samplingKeepsRequestedModuleOrdering() async {
        let coordinator = SamplingCoordinator()
        let previous = MonitorKind.allCases.map(MonitorModule.placeholder)

        let snapshot = await coordinator.sample(kinds: [.memory], previousModules: previous)

        #expect(snapshot?.modules.map(\.kind) == MonitorKind.allCases)
        #expect(snapshot?.modules.first(where: { $0.kind == .memory })?.summary != "--")
        let loadedKinds = await coordinator.loadedSamplerKinds()
        #expect(loadedKinds == [.memory])

        await coordinator.retainSamplers(for: [])

        let releasedKinds = await coordinator.loadedSamplerKinds()
        #expect(releasedKinds.isEmpty)
    }

    @Test func samplingLoadsEveryRequestedWorkerAndNothingElse() async {
        let coordinator = SamplingCoordinator()
        let previous = MonitorKind.allCases.map(MonitorModule.placeholder)

        let snapshot = await coordinator.sample(
            kinds: [.cpu, .memory, .battery],
            previousModules: previous,
            panelVisible: false
        )

        #expect(snapshot != nil)
        let loadedKinds = await coordinator.loadedSamplerKinds()
        #expect(loadedKinds == [.cpu, .memory, .battery])
        #expect(!loadedKinds.contains(.network))
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
