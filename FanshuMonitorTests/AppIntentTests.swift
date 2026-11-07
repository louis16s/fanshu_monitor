import AppIntents
import Testing
@testable import FanshuMonitor

struct AppIntentTests {
    @Test func shortcutsExposeBothActionsWithoutOpeningTheApp() {
        #expect(FanshuMonitorShortcuts.appShortcuts.count == 2)
        #expect(!GetPowerFlowIntent.openAppWhenRun)
        #expect(!LockScreenNowIntent.openAppWhenRun)
    }

    @Test func powerFlowIntentCompletesWithLiveOrUnavailableTelemetry() async throws {
        _ = try await GetPowerFlowIntent().perform()
    }
}
