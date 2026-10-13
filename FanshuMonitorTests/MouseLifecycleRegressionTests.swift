import Foundation
import Testing
@testable import FanshuMonitor

private final class MouseRestartScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func schedule(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { self.action = action }
    }

    var isScheduled: Bool { lock.withLock { action != nil } }

    func fire() {
        let pending = lock.withLock {
            let pending = action
            action = nil
            return pending
        }
        pending?()
    }
}

struct MouseLifecycleRegressionTests {
    @Test @MainActor func revokedPermissionStopsExistingTapAndReauthorizationRecreatesIt() {
        let suite = "MouseLifecycleRegressionTests.permissions"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MonitorSettings(defaults: defaults)
        var granted = true
        var starts = 0
        var stops = 0
        let tap = MouseButtonEventTap(
            settings: settings, permissionProvider: { granted },
            startOverride: { starts += 1; return true }, stopOverride: { stops += 1 }
        )
        #expect(tap.start())
        #expect(tap.start())
        #expect(starts == 1)
        granted = false
        #expect(!tap.start())
        #expect(stops == 1)
        granted = true
        #expect(tap.start())
        #expect(starts == 2)
        tap.stop()
    }

    @Test @MainActor func suspensionDuringRestartBackoffCompletes() async {
        let scheduler = MouseRestartScheduler()
        let listener = LogitechHIDPPButtonListener(
            workerOverride: {}, restartScheduler: { _, action in scheduler.schedule(action) }
        )
        listener.start()
        for _ in 0..<100 where !scheduler.isScheduled { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(scheduler.isScheduled)
        var completed = false
        let operation = Task { @MainActor in
            await listener.suspendForDeviceOperation()
            completed = true
            listener.resumeAfterDeviceOperation()
        }
        for _ in 0..<100 where !listener.hasPendingDeviceOperation { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(listener.hasPendingDeviceOperation)
        scheduler.fire()
        for _ in 0..<100 where !completed { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(completed)
        listener.stop()
        scheduler.fire()
        operation.cancel()
    }
}
