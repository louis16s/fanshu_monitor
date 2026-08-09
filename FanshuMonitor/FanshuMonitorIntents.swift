import AppIntents
import Foundation

struct GetPowerFlowIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.power-flow.title"
    static let description = IntentDescription("shortcut.power-flow.description")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let telemetry = BatteryPowerTelemetryReader.readCurrent() else {
            let message = String(localized: "shortcut.power-flow.unavailable")
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }

        let input = wattStringAllowZero(telemetry.adapterInputWatts)
        let system = wattString(telemetry.resolvedSystemLoadWatts)
        let battery = BatteryPowerTelemetry.batteryFlowText(telemetry.batteryWatts)
        let message = String(
            format: String(localized: "shortcut.power-flow.result"),
            input,
            system,
            battery
        )
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct LockScreenNowIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.lock-screen.title"
    static let description = IntentDescription("shortcut.lock-screen.description")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await LockScreenAttemptRunner.run(
            timing: .standard,
            requestNativeLock: DirectScreenLocker.requestNativeLock,
            requestKeyboardLock: DirectScreenLocker.requestKeyboardLock,
            isScreenLocked: SystemSessionState.isScreenLocked
        )
        let key = result == .locked
            ? "shortcut.lock-screen.success"
            : "shortcut.lock-screen.failed"
        return .result(dialog: IntentDialog(stringLiteral: String(localized: String.LocalizationValue(key))))
    }
}

struct FanshuMonitorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetPowerFlowIntent(),
            phrases: [
                "用 \(.applicationName) 查看功率分流",
                "Get power flow with \(.applicationName)"
            ],
            shortTitle: "shortcut.power-flow.short-title",
            systemImageName: "bolt.horizontal.circle"
        )
        AppShortcut(
            intent: LockScreenNowIntent(),
            phrases: [
                "用 \(.applicationName) 立即锁屏",
                "Lock my Mac with \(.applicationName)"
            ],
            shortTitle: "shortcut.lock-screen.short-title",
            systemImageName: "lock.fill"
        )
    }
}
