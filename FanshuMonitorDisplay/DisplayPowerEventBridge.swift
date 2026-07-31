import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

nonisolated private let messageCanSystemSleep: natural_t = 0xe000_0270
nonisolated private let messageSystemWillSleep: natural_t = 0xe000_0280
nonisolated private let messageSystemHasPoweredOn: natural_t = 0xe000_0300
nonisolated private let messageSystemWillPowerOn: natural_t = 0xe000_0320

nonisolated enum DisplayPowerEvent: Sendable {
    case willSleep
    case willPowerOn
    case hasPoweredOn
}

nonisolated final class DisplayPowerEventBridge: @unchecked Sendable {
    private let handler: @MainActor @Sendable (DisplayPowerEvent) -> Void
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping @MainActor @Sendable (DisplayPowerEvent) -> Void) {
        self.handler = handler
    }

    func start() {
        guard rootPort == 0 else { return }

        var port: IONotificationPortRef?
        var notification: io_object_t = 0
        let connection = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &port,
            displayPowerCallback,
            &notification
        )
        guard connection != 0, let port else {
            AppLogger.ui.error("Unable to register early display power notifications")
            return
        }

        rootPort = connection
        notificationPort = port
        notifier = notification
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    fileprivate func receive(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case messageCanSystemSleep, messageSystemWillSleep:
            if messageType == messageSystemWillSleep {
                send(.willSleep)
            }
            if let argument {
                IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            }
        case messageSystemWillPowerOn:
            send(.willPowerOn)
        case messageSystemHasPoweredOn:
            send(.hasPoweredOn)
        default:
            break
        }
    }

    private func send(_ event: DisplayPowerEvent) {
        Task { @MainActor [handler] in
            handler(event)
        }
    }

    deinit {
        stop()
    }
}

nonisolated(unsafe) private let displayPowerCallback: IOServiceInterestCallback = {
    refcon,
    _,
    messageType,
    messageArgument
in
    guard let refcon else { return }
    Unmanaged<DisplayPowerEventBridge>
        .fromOpaque(refcon)
        .takeUnretainedValue()
        .receive(messageType: messageType, argument: messageArgument)
}
