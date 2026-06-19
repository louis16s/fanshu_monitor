import AppKit
import ApplicationServices
import Combine
import Foundation
import IOKit.hid
import OSLog

enum MouseButtonSlot: String, CaseIterable, Identifiable {
    case middle
    case back
    case forward
    case gesture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .middle: "中键"
        case .back: "后退键"
        case .forward: "前进键"
        case .gesture: "手势键"
        }
    }

    static let settingsOrder: [MouseButtonSlot] = [.middle, .gesture, .back, .forward]
}

enum MouseButtonAction: String, CaseIterable, Identifiable {
    case passThrough
    case browserBack
    case browserForward
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case commandTab
    case copy
    case paste
    case functionF13
    case functionF14
    case functionF15

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passThrough: "透传"
        case .browserBack: "浏览器后退"
        case .browserForward: "浏览器前进"
        case .missionControl: "调度中心"
        case .appExpose: "应用窗口"
        case .showDesktop: "显示桌面"
        case .launchpad: "启动台"
        case .commandTab: "切换应用"
        case .copy: "复制"
        case .paste: "粘贴"
        case .functionF13: "功能键 F13"
        case .functionF14: "功能键 F14"
        case .functionF15: "功能键 F15"
        }
    }
}

struct LogitechMouseDevice: Identifiable, Equatable {
    let productID: Int
    let productName: String
    let transport: String
    let supportsDPI: Bool
    let dpiMin: Int
    let dpiMax: Int
    var currentDPI: Int?
    var batteryPercent: Int?

    var id: String {
        "\(productID)-\(productName)-\(transport)"
    }

    var displayName: String {
        if productID == 0xB037 || productName.localizedCaseInsensitiveContains("Anywhere 3S") {
            return "MX Anywhere 3S"
        }
        return productName.isEmpty ? "Logitech 鼠标" : productName
    }
}

@MainActor
final class MouseControlController: ObservableObject {
    @Published private(set) var device: LogitechMouseDevice?
    @Published private(set) var statusText = "未启用"
    @Published private(set) var buttonStatusText = "未启用"
    @Published private(set) var isApplyingDPI = false
    var deviceStatusLine: String {
        let battery = device?.batteryPercent.map { " · 电量 \($0)%" } ?? ""
        return "\(buttonStatusText)\(battery)"
    }
    var combinedStatusLine: String {
        let battery = device?.batteryPercent.map { " · 电量 \($0)%" } ?? ""
        guard settings?.mouseControlEnabled == true else {
            return "未启用"
        }
        return "\(buttonStatusText) · \(statusText)\(battery)"
    }

    private weak var settings: MonitorSettings?
    private let hidService = LogitechHIDPPService()
    private var eventTap: MouseButtonEventTap?
    private var hidButtonListener: LogitechHIDPPButtonListener?
    private var cancellables = Set<AnyCancellable>()

    func configure(settings: MonitorSettings) {
        self.settings = settings
        eventTap = MouseButtonEventTap(settings: settings)
        hidButtonListener = LogitechHIDPPButtonListener(settings: settings)

        settings.$mouseControlEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.syncEnabledState(enabled)
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.eventTap?.refresh()
            }
            .store(in: &cancellables)

        syncEnabledState(settings.mouseControlEnabled)
    }

    func refreshIfNeeded() {
        guard settings?.mouseControlEnabled == true else { return }
        refresh()
    }

    func refreshButtonTapIfPossible() {
        guard settings?.mouseControlEnabled == true else { return }
        if eventTap?.start() == true {
            buttonStatusText = "按钮监听已启用"
        }
    }

    func refresh() {
        guard settings?.mouseControlEnabled == true else {
            device = nil
            statusText = "未启用"
            return
        }

        statusText = "正在检测鼠标"
        Task { [weak self, hidService] in
            let result = await Task.detached(priority: .utility) {
                hidService.detectDevice(readDPI: true)
            }.value
            guard let self else { return }
            self.device = result
            if let result {
                let dpi = result.currentDPI.map { " · \($0) DPI" } ?? ""
                self.statusText = "\(result.displayName)\(dpi)"
            } else {
                self.statusText = "未发现支持的 Logitech 鼠标"
            }
        }
    }

    func applyDPI(_ value: Int) {
        guard settings?.mouseControlEnabled == true else { return }
        let clamped = min(8000, max(200, value))
        isApplyingDPI = true
        statusText = "正在设置 DPI"

        Task { [weak self, hidService] in
            let success = await Task.detached(priority: .utility) {
                hidService.setDPI(clamped)
            }.value
            guard let self else { return }
            self.isApplyingDPI = false
            if success {
                var updated = self.device
                updated?.currentDPI = clamped
                self.device = updated
                self.statusText = "\(updated?.displayName ?? "Logitech 鼠标") · \(clamped) DPI"
            } else {
                self.statusText = "DPI 未应用"
            }
        }
    }

    private func syncEnabledState(_ enabled: Bool) {
        if enabled {
            if eventTap?.start() == true {
                buttonStatusText = "按钮监听已启用"
            } else {
                buttonStatusText = "等待辅助功能授权"
            }
            hidButtonListener?.start()
            refresh()
        } else {
            eventTap?.stop()
            hidButtonListener?.stop()
            device = nil
            statusText = "未启用"
            buttonStatusText = "未启用"
        }
    }
}

private final class MouseButtonEventTap {
    private weak var settings: MonitorSettings?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let actionQueue = DispatchQueue(label: "com.fanshu.monitor.mouse-actions", qos: .userInitiated)

    init(settings: MonitorSettings) {
        self.settings = settings
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else {
            AppLogger.mouse.info("Mouse button tap waiting for Accessibility permission")
            return false
        }

        let mask = (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.callback,
            userInfo: pointer
        ) else {
            AppLogger.mouse.error("Mouse button tap creation failed")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.mouse.info("Mouse button tap started")
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        AppLogger.mouse.info("Mouse button tap stopped")
    }

    func refresh() {
        if settings?.mouseControlEnabled == true {
            start()
        } else {
            stop()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard settings?.mouseControlEnabled == true else {
            return Unmanaged.passUnretained(event)
        }

        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        let slot: MouseButtonSlot?
        switch buttonNumber {
        case 2: slot = .middle
        case 3: slot = .back
        case 4: slot = .forward
        default: slot = nil
        }

        guard let slot else {
            return Unmanaged.passUnretained(event)
        }

        let action = settings?.mouseAction(for: slot) ?? .passThrough
        guard action != .passThrough else {
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown {
            AppLogger.mouse.debug("Mouse button \(slot.rawValue, privacy: .public) mapped to \(action.rawValue, privacy: .public)")
            actionQueue.async {
                MouseActionExecutor.execute(action)
            }
        }
        return nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let tap = Unmanaged<MouseButtonEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                if let eventTap = tap.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                    AppLogger.mouse.info("Mouse button tap re-enabled by callback")
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let tap = Unmanaged<MouseButtonEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }
}

private final class LogitechHIDPPButtonListener: @unchecked Sendable {
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

private enum MouseActionExecutor {
    @_silgen_name("CoreDockSendNotification")
    private static func coreDockSendNotification(_ name: CFString, _ unknown: Int32) -> Int32

    static func execute(_ action: MouseButtonAction) {
        switch action {
        case .passThrough:
            return
        case .browserBack:
            key(.leftArrow, modifiers: .maskCommand)
        case .browserForward:
            key(.rightArrow, modifiers: .maskCommand)
        case .missionControl:
            if !dockNotification("com.apple.expose.awake") {
                key(.upArrow, modifiers: .maskControl)
            }
        case .appExpose:
            if !dockNotification("com.apple.expose.front.awake") {
                key(.downArrow, modifiers: .maskControl)
            }
        case .showDesktop:
            if !dockNotification("com.apple.showdesktop.awake") {
                key(.f11, modifiers: [])
            }
        case .launchpad:
            if !dockNotification("com.apple.launchpad.toggle") {
                key(.f4, modifiers: [])
            }
        case .commandTab:
            key(.tab, modifiers: .maskCommand)
        case .copy:
            key(.keyC, modifiers: .maskCommand)
        case .paste:
            key(.keyV, modifiers: .maskCommand)
        case .functionF13:
            key(.f13, modifiers: [])
        case .functionF14:
            key(.f14, modifiers: [])
        case .functionF15:
            key(.f15, modifiers: [])
        }
    }

    private static func dockNotification(_ name: String) -> Bool {
        coreDockSendNotification(name as CFString, 0) == 0
    }

    private static func key(_ keyCode: CGKeyCode, modifiers: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private extension CGKeyCode {
    static let tab: CGKeyCode = 48
    static let space: CGKeyCode = 49
    static let keyC: CGKeyCode = 8
    static let keyV: CGKeyCode = 9
    static let leftArrow: CGKeyCode = 123
    static let rightArrow: CGKeyCode = 124
    static let downArrow: CGKeyCode = 125
    static let upArrow: CGKeyCode = 126
    static let f4: CGKeyCode = 118
    static let f11: CGKeyCode = 103
    static let f13: CGKeyCode = 105
    static let f14: CGKeyCode = 107
    static let f15: CGKeyCode = 113
}

nonisolated private final class LogitechHIDPPService: @unchecked Sendable {
    private enum Constants {
        static let vendorID = 0x046D
        static let mxAnywhere3SProductID = 0xB037
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
        for device in enumerateLogitechDevices() {
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

    private nonisolated func enumerateLogitechDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kIOHIDVendorIDKey as String: Constants.vendorID] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return []
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }
        return Array(set).filter { device in
            let productID = Self.intProperty(device, kIOHIDProductIDKey as CFString)
            let name = Self.stringProperty(device, kIOHIDProductKey as CFString)
            return productID == Constants.mxAnywhere3SProductID
                || name.localizedCaseInsensitiveContains("MX Anywhere")
                || name.localizedCaseInsensitiveContains("Logitech")
        }
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
                dpiMax: productID == Constants.mxAnywhere3SProductID ? 8000 : 4000,
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
