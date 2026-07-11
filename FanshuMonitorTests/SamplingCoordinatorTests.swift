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
