import Foundation
import IOKit.hid
import OSLog

nonisolated final class LogitechHIDPPButtonListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fanshu.monitor.hidpp-buttons", qos: .utility)
    private let stateLock = NSLock()
    private var desiredRunning = false
    private var workerActive = false
    private var restartAttempt = 0
    private var workerRunLoop: CFRunLoop?
    private var gestureMapping = MouseButtonMapping(action: .passThrough, shortcut: nil)

    deinit {
        stop()
    }

    func updateMapping(_ mapping: MouseButtonMapping) {
        stateLock.withLock {
            gestureMapping = mapping
        }
    }

    func start() {
        let shouldStartWorker = stateLock.withLock {
            desiredRunning = true
            guard !workerActive else { return false }
            workerActive = true
            return true
        }
        guard shouldStartWorker else { return }
        launchWorker()
    }

    private func launchWorker() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listen()
            self.workerDidExit()
        }
    }

    func stop() {
        let runLoop = stateLock.withLock {
            desiredRunning = false
            restartAttempt = 0
            return workerRunLoop
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private func listen() {
        autoreleasepool {
            guard let device = Self.enumerateLogitechDevices().first else { return }

            let client = Client(device: device)
            guard client.open() else { return }
            defer {
                client.close()
            }

            guard client.configureGestureReporting() else { return }

            client.startGestureEvents { [weak self] in
                guard let self else { return }
                let mapping = self.currentGestureMapping
                guard mapping.isExecutable else { return }
                Task { @MainActor in
                    MouseActionExecutor.execute(mapping)
                }
            }

            AppLogger.mouse.info("HID++ gesture button listener started")
            let runLoop = CFRunLoopGetCurrent()
            stateLock.withLock {
                workerRunLoop = runLoop
                restartAttempt = 0
            }
            defer {
                stateLock.withLock {
                    if workerRunLoop === runLoop {
                        workerRunLoop = nil
                    }
                }
            }
            while shouldContinue {
                let result = CFRunLoopRunInMode(.defaultMode, 0.5, true)
                if result == .finished || result == .stopped {
                    break
                }
            }
        }
    }

    private var shouldContinue: Bool {
        stateLock.withLock { desiredRunning }
    }

    private func workerDidExit() {
        let restartDelay = stateLock.withLock { () -> TimeInterval? in
            workerActive = false
            workerRunLoop = nil
            guard desiredRunning else { return nil }
            let delay = min(30, pow(2, Double(restartAttempt)))
            restartAttempt = min(restartAttempt + 1, 5)
            workerActive = true
            return delay
        }
        if let restartDelay {
            queue.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
                guard let self else { return }
                guard self.shouldContinue else {
                    self.stateLock.withLock { self.workerActive = false }
                    return
                }
                self.launchWorker()
            }
        }
    }

    private var currentGestureMapping: MouseButtonMapping {
        stateLock.withLock { gestureMapping }
    }

    private static func enumerateLogitechDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey as String: LogitechMouseDeviceMatcher.vendorID] as CFDictionary
        )
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(set).filter(LogitechMouseDeviceMatcher.isSupported)
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
        private var gestureHandler: (@Sendable () -> Void)?
        private var isAwaitingResponse = false

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

        func startGestureEvents(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock {
                gestureHandler = handler
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
            lock.withLock {
                reports.removeAll(keepingCapacity: true)
                isAwaitingResponse = true
            }
            defer {
                lock.withLock {
                    isAwaitingResponse = false
                    reports.removeAll(keepingCapacity: true)
                }
            }
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
            let handler = lock.withLock {
                if isAwaitingResponse {
                    reports.append(report)
                }
                return gestureHandler
            }
            handleGestureReport(report, handler: handler)
        }

        private func handleGestureReport(_ report: [UInt8], handler: (@Sendable () -> Void)?) {
            guard let parsed = HIDPPResponse(report: report),
                  parsed.featureIndex == reprogFeature,
                  parsed.function == 0,
                  let gestureCID else {
                return
            }
            let isHeld = Self.cids(in: parsed.params).contains(gestureCID)
            if isHeld && !gestureHeld {
                gestureHeld = true
            } else if !isHeld && gestureHeld {
                gestureHeld = false
                handler?()
            }
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
