import AppKit
import Foundation
import IOKit.ps

/// Owns operating-system notifications used by the lock policy feature.
/// Policy decisions stay in `LockScreenPolicyController`; this type only
/// translates lifecycle events into main-actor callbacks.
@MainActor
final class LockScreenSystemObserver {
    typealias Handler = @MainActor @Sendable () -> Void

    struct Handlers {
        let didWake: Handler
        let willSleep: Handler
        let sessionBecameActive: Handler
        let sessionResignedActive: Handler
        let timeChanged: Handler
        let screenLocked: Handler
        let screenUnlocked: Handler
        let sessionWatchdog: Handler
        let powerSourceChanged: Handler
        let willTerminate: Handler
    }

    private var workspaceObservers: [NSObjectProtocol] = []
    private var systemObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var sessionWatchdogTimer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var powerSourceHandler: Handler?

    func start(using handlers: Handlers) {
        guard workspaceObservers.isEmpty,
              systemObservers.isEmpty,
              distributedObservers.isEmpty else {
            return
        }

        powerSourceHandler = handlers.powerSourceChanged
        setPowerSourceObserving(true)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in handlers.didWake() }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in handlers.willSleep() }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in handlers.sessionBecameActive() }
            },
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in handlers.sessionResignedActive() }
            }
        ]
        systemObservers = [
            NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
                Task { @MainActor in handlers.timeChanged() }
            },
            NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemClockDidChange, object: nil, queue: .main) { _ in
                Task { @MainActor in handlers.timeChanged() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in handlers.willTerminate() }
            }
        ]

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers = [
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in handlers.screenLocked() }
            },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in handlers.screenUnlocked() }
            }
        ]

        sessionWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in handlers.sessionWatchdog() }
        }
        sessionWatchdogTimer?.tolerance = 5
    }

    func setPowerSourceObserving(_ enabled: Bool) {
        if !enabled {
            if let powerSourceRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
            }
            powerSourceRunLoopSource = nil
            return
        }
        guard powerSourceRunLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSourceRunLoopSource = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let observer = Unmanaged<LockScreenSystemObserver>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor in
                observer.powerSourceHandler?()
            }
        }, context)?.takeRetainedValue()
        if let powerSourceRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
        }
    }

    func stop() {
        sessionWatchdogTimer?.invalidate()
        sessionWatchdogTimer = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        systemObservers.forEach(NotificationCenter.default.removeObserver)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        workspaceObservers.removeAll()
        systemObservers.removeAll()
        distributedObservers.removeAll()
        setPowerSourceObserving(false)
        powerSourceHandler = nil
    }

    deinit {
        sessionWatchdogTimer?.invalidate()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        systemObservers.forEach(NotificationCenter.default.removeObserver)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .commonModes)
        }
    }

}
