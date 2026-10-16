import Foundation
import ApplicationServices
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
    @Test @MainActor func repeatedMouseDownExecutesOnceUntilTheMatchingRelease() {
        let suite = "MouseLifecycleRegressionTests.buttonPairing"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MonitorSettings(defaults: defaults)
        settings.mouseControlEnabled = true
        settings.mouseBackAction = .paste
        var actions: [MouseButtonAction] = []
        let tap = MouseButtonEventTap(settings: settings, executeAction: { actions.append($0.action) })
        let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                            mouseCursorPosition: .zero, mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3)

        #expect(tap.handle(type: .otherMouseDown, event: event) == nil)
        #expect(tap.handle(type: .otherMouseDown, event: event) == nil)
        #expect(actions == [.paste])
        settings.mouseBackAction = .passThrough
        #expect(tap.handle(type: .otherMouseUp, event: event) == nil)
        #expect(tap.handle(type: .otherMouseDown, event: event) != nil)
        settings.mouseBackAction = .copy
        #expect(tap.handle(type: .otherMouseUp, event: event) != nil)
        #expect(tap.handle(type: .otherMouseDown, event: event) == nil)
        #expect(actions == [.paste, .copy])
        #expect(tap.handle(type: .otherMouseUp, event: event) == nil)
    }

    @Test @MainActor func ownGeneratedEventsNeverTriggerAnotherMouseAction() {
        let defaults = UserDefaults(suiteName: "MouseLifecycleRegressionTests.generatedEvents")!
        defer { defaults.removePersistentDomain(forName: "MouseLifecycleRegressionTests.generatedEvents") }
        let settings = MonitorSettings(defaults: defaults)
        settings.mouseControlEnabled = true
        settings.mouseBackAction = .paste
        var executed = false
        let tap = MouseButtonEventTap(settings: settings, executeAction: { _ in executed = true })
        let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                            mouseCursorPosition: .zero, mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        event.setIntegerValueField(.eventSourceUserData, value: MouseActionExecutor.generatedEventMarker)

        #expect(tap.handle(type: .otherMouseDown, event: event) != nil)
        #expect(!executed)
    }

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

private nonisolated final class MousePostedEvents: @unchecked Sendable {
    struct Entry {
        let keyCode: Int64
        let flags: CGEventFlags
        let marker: Int64
        let onMainThread: Bool
    }
    private let lock = NSLock()
    private var storage: [Entry] = []

    func record(_ event: CGEvent) {
        let entry = Entry(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            marker: event.getIntegerValueField(.eventSourceUserData),
            onMainThread: Thread.isMainThread
        )
        lock.withLock { storage.append(entry) }
    }

    var entries: [Entry] { lock.withLock { storage } }
}

struct MouseActionExecutorTests {
    @Test @MainActor func copyAndPasteAreOrderedOffMainAndReleaseCommand() {
        let queue = DispatchQueue(label: "MouseActionExecutorTests.ordered")
        let posted = MousePostedEvents()
        let executor = MouseActionExecutor(queue: queue, postEvent: { posted.record($0) })
        #expect(executor.enqueue(MouseButtonMapping(action: .copy, shortcut: nil)))
        #expect(executor.enqueue(MouseButtonMapping(action: .paste, shortcut: nil)))
        queue.sync {}

        let events = posted.entries
        #expect(events.map(\.keyCode) == [8, 8, 9, 9])
        #expect(events.map(\.flags) == [.maskCommand, [], .maskCommand, []])
        #expect(events.allSatisfy { !$0.onMainThread })
        #expect(events.allSatisfy { $0.marker == MouseActionExecutor.generatedEventMarker })
    }

    @Test func eventStormHasABoundedQueueAndRecoversAfterDraining() {
        let queue = DispatchQueue(label: "MouseActionExecutorTests.bounded")
        let posted = MousePostedEvents()
        let executor = MouseActionExecutor(queue: queue, postEvent: { posted.record($0) })
        let mapping = MouseButtonMapping(action: .copy, shortcut: nil)
        queue.suspend()
        for _ in 0..<MouseActionExecutor.maximumPendingActions {
            #expect(executor.enqueue(mapping))
        }
        #expect(!executor.enqueue(mapping))
        queue.resume()
        queue.sync {}
        #expect(posted.entries.count == MouseActionExecutor.maximumPendingActions * 2)
        #expect(executor.enqueue(mapping))
        queue.sync {}
        #expect(posted.entries.count == (MouseActionExecutor.maximumPendingActions + 1) * 2)
    }
}
