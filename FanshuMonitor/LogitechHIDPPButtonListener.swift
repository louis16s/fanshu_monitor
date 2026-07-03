import Foundation
import IOKit.hid
import OSLog

final class LogitechHIDPPButtonListener: @unchecked Sendable {
    private weak var settings: MonitorSettings?
    private let queue = DispatchQueue(label: "com.fanshu.monitor.hidpp-buttons", qos: .utility)
    private let actionQueue = DispatchQueue(label: "com.fanshu.monitor.hidpp-actions", qos: .userInitiated)
    private var isRunning = false
    private var client: Client?

    init(settings: MonitorSettings) {
        self.settings = settings
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.listen()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.isRunning = false
            self?.client?.close()
            self?.client = nil
        }
    }

    private func listen() {
        while isRunning {
            autoreleasepool {
                guard let device = Self.enumerateLogitechDevices().first else {
                    Thread.sleep(forTimeInterval: 2)
                    return
                }

                let client = Client(device: device)
                self.client = client
                guard client.open() else {
                    Thread.sleep(forTimeInterval: 2)
                    return
                }
                defer {
                    client.close()
                    self.client = nil
                }

                guard client.configureGestureReporting() else {
                    Thread.sleep(forTimeInterval: 2)
                    return
                }

                AppLogger.mouse.info("HID++ gesture button listener started")
                while isRunning, settings?.mouseControlEnabled == true {
                    client.pumpReports { [weak self] isGestureUp in
                        guard isGestureUp,
                              let action = self?.settings?.mouseAction(for: .gesture),
                              action != .passThrough else {
                            return
                        }
                        self?.actionQueue.async {
                            MouseActionExecutor.execute(action)
                        }
                    }
                    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, true)
                }
            }
        }
    }

    private static func enumerateLogitechDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey as String: 0x046D] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(set).filter { device in
            let productID = intProperty(device, kIOHIDProductIDKey as CFString)
            let name = stringProperty(device, kIOHIDProductKey as CFString)
            return productID == 0xB037
                || name.localizedCaseInsensitiveContains("MX Anywhere")
                || name.localizedCaseInsensitiveContains("Logitech")
        }
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: CFString) -> Int {
        (IOHIDDeviceGetProperty(device, key) as? NSNumber)?.intValue ?? 0
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: CFString) -> String {
        IOHIDDeviceGetProperty(device, key) as? String ?? ""
    }

    private final class Client {
        private static let reportID: UInt8 = 0x11
        private static let reportLength = 20
        private static let softwareID: UInt8 = 0x0A
        private static let reprogControlsV4 = 0x1B04
        private static let gestureCIDs = [0x00C3, 0x00D7]

        private let device: IOHIDDevice
        private var inputBuffer: UnsafeMutablePointer<UInt8>?
        private let lock = NSLock()
        private var reports: [[UInt8]] = []
        private var deviceIndex: UInt8 = 0xFF
        private var reprogFeature: UInt8?
        private var gestureCID: Int?
        private var gestureHeld = false

        init(device: IOHIDDevice) {
            self.device = device
        }

        func open() -> Bool {
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                return false
            }
            inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            inputBuffer?.initialize(repeating: 0, count: 64)
            if let inputBuffer {
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    inputBuffer,
                    64,
                    Self.reportCallback,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            }
            return true
        }

        func close() {
            if let gestureCID, let reprogFeature {
                let hi = UInt8((gestureCID >> 8) & 0xFF)
                let lo = UInt8(gestureCID & 0xFF)
                _ = request(featureIndex: reprogFeature, function: 3, params: [hi, lo, 0x02, 0, 0], timeout: 0.25)
            }
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            inputBuffer?.deinitialize(count: 64)
            inputBuffer?.deallocate()
            inputBuffer = nil
        }

        func configureGestureReporting() -> Bool {
            guard let feature = findFeature(Self.reprogControlsV4) else { return false }
            reprogFeature = feature
            for cid in Self.gestureCIDs {
                let hi = UInt8((cid >> 8) & 0xFF)
                let lo = UInt8(cid & 0xFF)
                if request(featureIndex: feature, function: 3, params: [hi, lo, 0x03, 0, 0], timeout: 0.7) != nil {
                    gestureCID = cid
                    return true
                }
            }
            return false
        }

        func pumpReports(onGestureUp: (Bool) -> Void) {
            let snapshot = takeReports()
            for report in snapshot {
                guard let parsed = HIDPPResponse(report: report),
                      parsed.featureIndex == reprogFeature,
                      parsed.function == 0,
                      let gestureCID else {
                    continue
                }
                let cids = Self.cids(in: parsed.params)
                let isHeld = cids.contains(gestureCID)
                if isHeld && !gestureHeld {
                    gestureHeld = true
                } else if !isHeld && gestureHeld {
                    gestureHeld = false
                    onGestureUp(true)
                }
            }
        }

        private func findFeature(_ featureID: Int) -> UInt8? {
            let hi = UInt8((featureID >> 8) & 0xFF)
            let lo = UInt8(featureID & 0xFF)
            for index in [UInt8(0xFF), 1, 2, 3, 4, 5, 6] {
                deviceIndex = index
                if let response = request(featureIndex: 0, function: 0, params: [hi, lo, 0], timeout: 0.7),
                   response.params.first ?? 0 != 0 {
                    return response.params[0]
                }
            }
            return nil
        }

        private func request(featureIndex: UInt8, function: UInt8, params: [UInt8], timeout: TimeInterval) -> HIDPPResponse? {
            _ = takeReports()
            transmit(featureIndex: featureIndex, function: function, params: params)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                for report in takeReports() {
                    guard let parsed = HIDPPResponse(report: report) else { continue }
                    if parsed.featureIndex == 0xFF { return nil }
                    let expected: Set<UInt8> = [function, (function + 1) & 0x0F]
                    if parsed.featureIndex == featureIndex,
                       parsed.softwareID == Self.softwareID,
                       expected.contains(parsed.function) {
                        return parsed
                    }
                }
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.02, true)
            }
            return nil
        }

        private func transmit(featureIndex: UInt8, function: UInt8, params: [UInt8]) {
            var report = [UInt8](repeating: 0, count: Self.reportLength)
            report[0] = Self.reportID
            report[1] = deviceIndex
            report[2] = featureIndex
            report[3] = ((function & 0x0F) << 4) | (Self.softwareID & 0x0F)
            for (index, param) in params.enumerated() where 4 + index < report.count {
                report[4 + index] = param
            }
            report.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let result = IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    CFIndex(Self.reportID),
                    baseAddress,
                    report.count
                )
                if result != kIOReturnSuccess {
                    _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, baseAddress, report.count)
                }
            }
        }

        private func takeReports() -> [[UInt8]] {
            lock.lock()
            let snapshot = reports
            reports.removeAll()
            lock.unlock()
            return snapshot
        }

        private func appendReport(_ report: [UInt8]) {
            lock.lock()
            reports.append(report)
            lock.unlock()
        }

        private static func cids(in params: [UInt8]) -> Set<Int> {
            var result = Set<Int>()
            var index = 0
            while index + 1 < params.count {
                let cid = Int(params[index]) << 8 | Int(params[index + 1])
                if cid == 0 { break }
                result.insert(cid)
                index += 2
            }
            return result
        }

        private static let reportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
            guard let context else { return }
            let client = Unmanaged<Client>.fromOpaque(context).takeUnretainedValue()
            client.appendReport(Array(UnsafeBufferPointer(start: report, count: reportLength)))
        }

        private struct HIDPPResponse {
            let featureIndex: UInt8
            let function: UInt8
            let softwareID: UInt8
            let params: [UInt8]

            init?(report: [UInt8]) {
                guard report.count >= 4 else { return nil }
                let offset = (report[0] == 0x10 || report[0] == 0x11) ? 1 : 0
                guard report.count > offset + 3 else { return nil }
                featureIndex = report[offset + 1]
                let functionAndSoftware = report[offset + 2]
                function = (functionAndSoftware >> 4) & 0x0F
                softwareID = functionAndSoftware & 0x0F
                params = Array(report.dropFirst(offset + 3))
            }
        }
    }
}
