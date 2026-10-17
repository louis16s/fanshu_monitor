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

nonisolated private final class DisplayPowerEventCallbackContext: @unchecked Sendable {
    weak var bridge: DisplayPowerEventBridge?
    var rootPort: io_connect_t = 0

    init(bridge: DisplayPowerEventBridge) {
        self.bridge = bridge
    }
}

nonisolated final class DisplayPowerEventBridge: @unchecked Sendable {
    private let earlyHandler: @Sendable (DisplayPowerEvent) -> Void
    private let handler: @MainActor @Sendable (DisplayPowerEvent) -> Void
    private let deliveryQueue = DispatchQueue(
        label: "fanshu.display-control.power-events",
        qos: .userInteractive
    )
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var retainedCallbackRefcon: UnsafeMutableRawPointer?

    init(
        earlyHandler: @escaping @Sendable (DisplayPowerEvent) -> Void = { _ in },
        handler: @escaping @MainActor @Sendable (DisplayPowerEvent) -> Void
    ) {
        self.earlyHandler = earlyHandler
        self.handler = handler
    }

    func start() {
        guard rootPort == 0 else { return }

        var port: IONotificationPortRef?
        var notification: io_object_t = 0
        let context = DisplayPowerEventCallbackContext(bridge: self)
        let callbackRefcon = Unmanaged.passRetained(context).toOpaque()
        let connection = IORegisterForSystemPower(
            callbackRefcon,
            &port,
            displayPowerCallback,
            &notification
        )
        guard connection != 0, let port else {
            Unmanaged<DisplayPowerEventCallbackContext>.fromOpaque(callbackRefcon).release()
            AppLogger.ui.error("Unable to register early display power notifications")
            return
        }

        context.rootPort = connection
        rootPort = connection
        notificationPort = port
        notifier = notification
        retainedCallbackRefcon = callbackRefcon
        IONotificationPortSetDispatchQueue(port, deliveryQueue)
    }

    func stop() {
        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        let rootPortToClose = rootPort
        rootPort = 0
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        guard let retainedCallbackRefcon else { return }
        self.retainedCallbackRefcon = nil
        let refconAddress = UInt(bitPattern: retainedCallbackRefcon)
        deliveryQueue.async {
            if rootPortToClose != 0 {
                IOServiceClose(rootPortToClose)
            }
            guard let refcon = UnsafeMutableRawPointer(bitPattern: refconAddress) else { return }
            Unmanaged<DisplayPowerEventCallbackContext>.fromOpaque(refcon).release()
        }
    }

    fileprivate func receive(
        messageType: natural_t,
        argument: UnsafeMutableRawPointer?,
        rootPort: io_connect_t
    ) {
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
        earlyHandler(event)
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
    let context = Unmanaged<DisplayPowerEventCallbackContext>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    context.bridge?.receive(
            messageType: messageType,
            argument: messageArgument,
            rootPort: context.rootPort
        )
}
