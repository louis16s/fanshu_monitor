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

nonisolated enum LogitechMouseDeviceDiscovery {
    static func supportedDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey as String: LogitechMouseDeviceMatcher.vendorID] as CFDictionary
        )
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }
        return devices.filter(LogitechMouseDeviceMatcher.isSupported)
    }

    static func hasSupportedDevice() -> Bool {
        !supportedDevices().isEmpty
    }
}

nonisolated final class LogitechMousePresenceMonitor: @unchecked Sendable {
    typealias PresenceHandler = @Sendable (Bool) -> Void

    private let queue = DispatchQueue(label: "com.fanshu.monitor.mouse-presence", qos: .utility)
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var handler: PresenceHandler?
    private var lastPresence: Bool?

    deinit {
        stop()
    }

    func start(handler: @escaping PresenceHandler) {
        let shouldStart = stateLock.withLock {
            self.handler = handler
            guard self.timer == nil else { return false }
            return true
        }
        guard shouldStart else {
            refresh()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .seconds(5),
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.publishPresence(force: false)
        }
        stateLock.withLock {
            self.timer = timer
            lastPresence = nil
        }
        timer.resume()
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
        let timer = stateLock.withLock {
            let value = self.timer
            self.timer = nil
            handler = nil
            lastPresence = nil
            return value
        }
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func publishPresence(force: Bool) {
        let snapshot = stateLock.withLock { (timer, handler, lastPresence) }
        guard let timer = snapshot.0, let handler = snapshot.1 else { return }
        let isPresent = LogitechMouseDeviceDiscovery.hasSupportedDevice()
        guard force || snapshot.2 != isPresent else { return }

        let shouldNotify = stateLock.withLock {
            guard self.timer === timer else { return false }
            lastPresence = isPresent
            return true
        }
        guard shouldNotify else { return }
        AppLogger.mouse.info("Logitech mouse presence changed: \(isPresent, privacy: .public)")
        handler(isPresent)
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

    func hasDevice() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: LogitechMouseDeviceDiscovery.hasSupportedDevice())
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
