import Foundation
import IOKit.hid

nonisolated final class LogitechHIDPPService: @unchecked Sendable {
    private enum Constants {
        static let longReportID: UInt8 = 0x11
        static let longReportLength = 20
        static let bluetoothDeviceIndex: UInt8 = 0xFF
        static let softwareID: UInt8 = 0x0A
        static let adjustableDPI = 0x2201
        static let unifiedBattery = 0x1004
        static let batteryStatus = 0x1000
    }

    nonisolated func detectDevice(readDPI: Bool) -> LogitechMouseDevice? {
        withClient { client in
            guard var device = client.deviceInfo else { return nil }
            if readDPI, client.findFeature(Constants.adjustableDPI) != nil {
                device.currentDPI = client.readDPI()
            }
            device.batteryPercent = client.readBattery()
            return device
        }
    }

    nonisolated func setDPI(_ dpi: Int) -> Bool {
        withClient { client in
            client.setDPI(min(8000, max(200, dpi)))
        } ?? false
    }

    private nonisolated func withClient<T>(_ operation: (HIDPPClient) -> T?) -> T? {
        for device in LogitechMouseDeviceDiscovery.supportedDevices() {
            let client = HIDPPClient(device: device)
            guard client.open() else { continue }
            defer { client.close() }
            if client.findFeature(Constants.adjustableDPI) != nil {
                return operation(client)
            }
            if client.deviceInfo != nil {
                return operation(client)
            }
        }
        return nil
    }

    private nonisolated static func intProperty(_ device: IOHIDDevice, _ key: CFString) -> Int {
        let value = IOHIDDeviceGetProperty(device, key)
        if let number = value as? NSNumber {
            return number.intValue
        }
        return 0
    }

    private nonisolated static func stringProperty(_ device: IOHIDDevice, _ key: CFString) -> String {
        IOHIDDeviceGetProperty(device, key) as? String ?? ""
    }

    private final class HIDPPClient {
        private let device: IOHIDDevice
        private var inputBuffer: UnsafeMutablePointer<UInt8>?
        private let lock = NSLock()
        private var reports: [[UInt8]] = []
        private var deviceIndex = Constants.bluetoothDeviceIndex

        init(device: IOHIDDevice) {
            self.device = device
        }

        var deviceInfo: LogitechMouseDevice? {
            let productID = LogitechHIDPPService.intProperty(device, kIOHIDProductIDKey as CFString)
            let productName = LogitechHIDPPService.stringProperty(device, kIOHIDProductKey as CFString)
            let transport = LogitechHIDPPService.stringProperty(device, kIOHIDTransportKey as CFString)
            guard productID != 0 || !productName.isEmpty else { return nil }
            return LogitechMouseDevice(
                productID: productID,
                productName: productName,
                transport: transport,
                supportsDPI: findFeature(Constants.adjustableDPI) != nil,
                dpiMin: 200,
                dpiMax: productID == LogitechMouseDeviceMatcher.mxAnywhere3SProductID ? 8000 : 4000,
                currentDPI: nil,
                batteryPercent: nil
            )
        }

        func open() -> Bool {
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                return false
            }
            inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            inputBuffer?.initialize(repeating: 0, count: 64)
            if let inputBuffer {
                let context = Unmanaged.passUnretained(self).toOpaque()
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    inputBuffer,
                    64,
                    Self.reportCallback,
                    context
                )
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            }
            return true
        }

        func close() {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            inputBuffer?.deinitialize(count: 64)
            inputBuffer?.deallocate()
            inputBuffer = nil
        }

        func findFeature(_ featureID: Int) -> UInt8? {
            let hi = UInt8((featureID >> 8) & 0xFF)
            let lo = UInt8(featureID & 0xFF)
            for index in [UInt8(0xFF), 1, 2, 3, 4, 5, 6] {
                deviceIndex = index
                if let response = request(featureIndex: 0, function: 0, params: [hi, lo, 0]),
                   response.params.first ?? 0 != 0 {
                    return response.params[0]
                }
            }
            return nil
        }

        func readDPI() -> Int? {
            guard let dpiFeature = findFeature(Constants.adjustableDPI),
                  let response = request(featureIndex: dpiFeature, function: 2, params: [0]),
                  response.params.count >= 3 else {
                return nil
            }
            return Int(response.params[1]) << 8 | Int(response.params[2])
        }

        func readBattery() -> Int? {
            if let batteryFeature = findFeature(Constants.unifiedBattery),
               let response = request(featureIndex: batteryFeature, function: 1, params: []),
               let level = response.params.first {
                return Int(min(100, max(0, level)))
            }
            if let batteryFeature = findFeature(Constants.batteryStatus),
               let response = request(featureIndex: batteryFeature, function: 0, params: []),
               let level = response.params.first {
                return Int(min(100, max(0, level)))
            }
            return nil
        }

        func setDPI(_ dpi: Int) -> Bool {
            guard let dpiFeature = findFeature(Constants.adjustableDPI) else {
                return false
            }
            let hi = UInt8((dpi >> 8) & 0xFF)
            let lo = UInt8(dpi & 0xFF)
            return request(featureIndex: dpiFeature, function: 3, params: [0, hi, lo]) != nil
        }

        private func request(featureIndex: UInt8, function: UInt8, params: [UInt8]) -> HIDPPResponse? {
            lock.lock()
            reports.removeAll()
            lock.unlock()

            transmit(featureIndex: featureIndex, function: function, params: params)
            let deadline = Date().addingTimeInterval(1.2)
            while Date() < deadline {
                if let response = nextMatchingResponse(featureIndex: featureIndex, function: function) {
                    return response
                }
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.02, true)
            }
            return nil
        }

        private func transmit(featureIndex: UInt8, function: UInt8, params: [UInt8]) {
            var report = [UInt8](repeating: 0, count: Constants.longReportLength)
            report[0] = Constants.longReportID
            report[1] = deviceIndex
            report[2] = featureIndex
            report[3] = ((function & 0x0F) << 4) | (Constants.softwareID & 0x0F)
            for (index, param) in params.enumerated() where 4 + index < report.count {
                report[4 + index] = param
            }

            report.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let result = IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    CFIndex(Constants.longReportID),
                    baseAddress,
                    report.count
                )
                if result != kIOReturnSuccess {
                    _ = IOHIDDeviceSetReport(
                        device,
                        kIOHIDReportTypeOutput,
                        0,
                        baseAddress,
                        report.count
                    )
                }
            }
        }

        private func nextMatchingResponse(featureIndex: UInt8, function: UInt8) -> HIDPPResponse? {
            lock.lock()
            let snapshot = reports
            reports.removeAll()
            lock.unlock()

            for report in snapshot {
                guard let parsed = HIDPPResponse(report: report) else { continue }
                if parsed.featureIndex == 0xFF {
                    return nil
                }
                let expectedFunctions: Set<UInt8> = [function, (function + 1) & 0x0F]
                if parsed.featureIndex == featureIndex,
                   parsed.softwareID == Constants.softwareID,
                   expectedFunctions.contains(parsed.function) {
                    return parsed
                }
            }
            return nil
        }

        private func appendReport(_ report: [UInt8]) {
            lock.lock()
            reports.append(report)
            lock.unlock()
        }

        private static let reportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
            guard let context else { return }
            let client = Unmanaged<HIDPPClient>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            client.appendReport(bytes)
        }
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
