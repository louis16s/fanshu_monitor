import Foundation
import IOKit.hid
import OSLog

nonisolated struct LogitechMouseDescriptor: Equatable, Sendable {
    let productID: Int
    let productName: String
    let primaryUsagePage: Int
    let primaryUsage: Int
}

nonisolated enum LogitechMouseDeviceMatcher {
    static let vendorID = 0x046D
    static let mxAnywhere3SProductID = 0xB037

    static func isSupported(_ descriptor: LogitechMouseDescriptor) -> Bool {
        if descriptor.productID == mxAnywhere3SProductID
            || descriptor.productName.localizedCaseInsensitiveContains("MX Anywhere") {
            return true
        }
        return descriptor.primaryUsagePage == 1
            && descriptor.primaryUsage == 2
            && descriptor.productName.localizedCaseInsensitiveContains("Logitech")
    }

    static func isSupported(_ device: IOHIDDevice) -> Bool {
        isSupported(descriptor(for: device))
    }

    static func descriptor(for device: IOHIDDevice) -> LogitechMouseDescriptor {
        LogitechMouseDescriptor(
            productID: intProperty(device, kIOHIDProductIDKey as CFString),
            productName: stringProperty(device, kIOHIDProductKey as CFString),
            primaryUsagePage: intProperty(device, kIOHIDPrimaryUsagePageKey as CFString),
            primaryUsage: intProperty(device, kIOHIDPrimaryUsageKey as CFString)
        )
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: CFString) -> Int {
        (IOHIDDeviceGetProperty(device, key) as? NSNumber)?.intValue ?? 0
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: CFString) -> String {
        IOHIDDeviceGetProperty(device, key) as? String ?? ""
    }
}

nonisolated final class LogitechMousePresenceMonitor: @unchecked Sendable {
    typealias PresenceHandler = @Sendable (Bool) -> Void

    private let queue = DispatchQueue(label: "com.fanshu.monitor.mouse-presence", qos: .utility)
    private let stateLock = NSLock()
    private var manager: IOHIDManager?
    private var handler: PresenceHandler?
    private var lastPresence: Bool?

    deinit {
        stop()
    }

    func start(handler: @escaping PresenceHandler) {
        let shouldStart = stateLock.withLock {
            self.handler = handler
            guard self.manager == nil else { return false }
            return true
        }
        guard shouldStart else {
            refresh()
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey as String: LogitechMouseDeviceMatcher.vendorID] as CFDictionary
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceChanged, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceChanged, context)
        IOHIDManagerSetDispatchQueue(manager, queue)

        stateLock.withLock {
            self.manager = manager
            lastPresence = nil
        }
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            stop()
            handler(false)
            return
        }
        IOHIDManagerActivate(manager)
        enqueuePresenceRefresh(force: false)
    }

    func refresh() {
        enqueuePresenceRefresh(force: true)
    }

    private func enqueuePresenceRefresh(force: Bool) {
        queue.async { [weak self] in
            self?.publishPresence(force: force)
        }
    }

    func stop() {
        let manager = stateLock.withLock {
            let value = self.manager
            self.manager = nil
            handler = nil
            lastPresence = nil
            return value
        }
        guard let manager else { return }
        queue.sync {
            IOHIDManagerCancel(manager)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private func publishPresence(force: Bool) {
        let snapshot = stateLock.withLock { (manager, handler, lastPresence) }
        guard let manager = snapshot.0, let handler = snapshot.1 else { return }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let isPresent = devices.contains(where: LogitechMouseDeviceMatcher.isSupported)
        guard force || snapshot.2 != isPresent else { return }

        let shouldNotify = stateLock.withLock {
            guard self.manager === manager else { return false }
            lastPresence = isPresent
            return true
        }
        guard shouldNotify else { return }
        AppLogger.mouse.info("Logitech mouse presence changed: \(isPresent, privacy: .public)")
        handler(isPresent)
    }

    private static let deviceChanged: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else { return }
        let monitor = Unmanaged<LogitechMousePresenceMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.publishPresence(force: false)
    }
}

nonisolated final class LogitechMouseWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fanshu.monitor.mouse-hidpp", qos: .utility)
    private let service = LogitechHIDPPService()

    func detectDevice(readDPI: Bool) async -> LogitechMouseDevice? {
        await withCheckedContinuation { continuation in
            queue.async { [service] in
                continuation.resume(returning: service.detectDevice(readDPI: readDPI))
            }
        }
    }

    func setDPI(_ dpi: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [service] in
                continuation.resume(returning: service.setDPI(dpi))
            }
        }
    }
}
