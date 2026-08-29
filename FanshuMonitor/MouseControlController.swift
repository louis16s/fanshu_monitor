import AppKit
import Combine
import Foundation

@MainActor
final class MouseControlController: ObservableObject {
    @Published private(set) var device: LogitechMouseDevice?
    @Published private(set) var statusText = "未启用"
    @Published private(set) var buttonStatusText = "未启用"
    @Published private(set) var isApplyingDPI = false
    var combinedStatusLine: String {
        let battery = device?.batteryPercent.map { " · 电量 \($0)%" } ?? ""
        guard settings?.mouseControlEnabled == true else {
            return "未启用"
        }
        return "\(buttonStatusText) · \(statusText)\(battery)"
    }

    private weak var settings: MonitorSettings?
    private let mouseWorker = LogitechMouseWorker()
    private let presenceMonitor = LogitechMousePresenceMonitor()
    private var eventTap: MouseButtonEventTap?
    private var hidButtonListener: LogitechHIDPPButtonListener?
    private var cancellables = Set<AnyCancellable>()
    private var deviceRequestGeneration: UInt64 = 0
    private var presenceSessionGeneration: UInt64 = 0
    private var isMousePresent = false

    func configure(settings: MonitorSettings) {
        if self.settings === settings, eventTap != nil, hidButtonListener != nil {
            syncEnabledState(settings.mouseControlEnabled)
            return
        }
        tearDown()
        self.settings = settings
        eventTap = MouseButtonEventTap(settings: settings)
        hidButtonListener = LogitechHIDPPButtonListener()

        settings.$mouseControlEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.syncEnabledState(enabled)
            }
            .store(in: &cancellables)

        settings.$mouseGestureAction
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncInputListeners()
            }
            .store(in: &cancellables)

        settings.$mouseCustomShortcuts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncInputListeners()
            }
            .store(in: &cancellables)

        syncEnabledState(settings.mouseControlEnabled)
    }

    func tearDown() {
        presenceSessionGeneration &+= 1
        deviceRequestGeneration &+= 1
        presenceMonitor.stop()
        eventTap?.stop()
        hidButtonListener?.stop()
        eventTap = nil
        hidButtonListener = nil
        cancellables.removeAll()
        isMousePresent = false
        device = nil
        isApplyingDPI = false
    }

    func refreshIfNeeded() {
        guard settings?.mouseControlEnabled == true else { return }
        if isMousePresent {
            refresh(readDPI: true)
        } else {
            presenceMonitor.refresh()
        }
    }

    func refreshButtonTapIfPossible() {
        guard settings?.mouseControlEnabled == true else { return }
        syncInputListeners()
    }

    func refresh() {
        guard settings?.mouseControlEnabled == true else { return }
        statusText = "正在检测鼠标"
        if isMousePresent {
            refresh(readDPI: true)
        } else {
            presenceMonitor.refresh()
        }
    }

    private func refresh(readDPI: Bool) {
        guard settings?.mouseControlEnabled == true else {
            suspendDeviceWork(status: "未启用")
            return
        }
        guard isMousePresent else {
            suspendDeviceWork(status: "等待鼠标连接")
            return
        }

        statusText = "正在检测鼠标"
        deviceRequestGeneration &+= 1
        isApplyingDPI = false
        let requestGeneration = deviceRequestGeneration
        let listener = hidButtonListener
        Task { [weak self, mouseWorker] in
            await listener?.suspendForDeviceOperation()
            let result = await mouseWorker.detectDevice(readDPI: readDPI)
            listener?.resumeAfterDeviceOperation()
            guard let self, requestGeneration == self.deviceRequestGeneration else { return }
            self.device = result
            if let result {
                if let currentDPI = result.currentDPI {
                    self.settings?.mouseDPI = Double(currentDPI)
                }
                let dpi = result.currentDPI.map { " · \($0) DPI" } ?? ""
                self.statusText = "\(result.displayName)\(dpi)"
                self.syncInputListeners()
            } else {
                self.suspendDeviceWork(status: "等待鼠标连接")
            }
        }
    }

    func applyDPI(_ value: Int) {
        guard settings?.mouseControlEnabled == true, device != nil else { return }
        let clamped = min(8000, max(200, value))
        deviceRequestGeneration &+= 1
        let requestGeneration = deviceRequestGeneration
        isApplyingDPI = true
        statusText = "正在设置 DPI"
        let listener = hidButtonListener

        Task { [weak self, mouseWorker] in
            await listener?.suspendForDeviceOperation()
            let success = await mouseWorker.setDPI(clamped)
            listener?.resumeAfterDeviceOperation()
            guard let self, requestGeneration == self.deviceRequestGeneration else { return }
            self.isApplyingDPI = false
            if success {
                var updated = self.device
                updated?.currentDPI = clamped
                self.device = updated
                self.settings?.mouseDPI = Double(clamped)
                self.statusText = "\(updated?.displayName ?? "Logitech 鼠标") · \(clamped) DPI"
            } else {
                self.statusText = "DPI 未应用"
            }
        }
    }

    private func syncEnabledState(_ enabled: Bool) {
        if enabled {
            presenceSessionGeneration &+= 1
            let sessionGeneration = presenceSessionGeneration
            statusText = "正在检测鼠标"
            buttonStatusText = "等待鼠标连接"
            syncInputListeners()
            presenceMonitor.start { [weak self] isPresent in
                Task { @MainActor [weak self] in
                    guard let self,
                          sessionGeneration == self.presenceSessionGeneration else {
                        return
                    }
                    self.mousePresenceDidChange(isPresent)
                }
            }
        } else {
            presenceSessionGeneration &+= 1
            presenceMonitor.stop()
            isMousePresent = false
            suspendDeviceWork(status: "未启用")
        }
    }

    private func mousePresenceDidChange(_ isPresent: Bool) {
        guard settings?.mouseControlEnabled == true else { return }
        isMousePresent = isPresent
        if isPresent {
            refresh(readDPI: !(settings?.mouseDPIOnDemandEnabled ?? true))
        } else {
            suspendDeviceWork(status: "等待鼠标连接")
        }
    }

    private func syncInputListeners() {
        let mouseControlEnabled = settings?.mouseControlEnabled == true
        let devicePresent = device != nil
        guard MouseInputListenerPolicy.shouldRunEventTap(
            mouseControlEnabled: mouseControlEnabled,
            devicePresent: devicePresent
        ) else {
            eventTap?.stop()
            hidButtonListener?.stop()
            buttonStatusText = mouseControlEnabled ? "等待鼠标连接" : "未启用"
            return
        }

        if eventTap?.start() == true {
            buttonStatusText = "按钮监听已启用"
        } else {
            buttonStatusText = "等待辅助功能授权"
        }

        let mapping = settings?.mouseMapping(for: .gesture)
            ?? MouseButtonMapping(action: .passThrough, shortcut: nil)
        hidButtonListener?.updateMapping(mapping)
        if MouseInputListenerPolicy.shouldRunHIDPPGesture(
            mouseControlEnabled: mouseControlEnabled,
            devicePresent: devicePresent,
            mapping: mapping
        ) {
            hidButtonListener?.start()
        } else {
            hidButtonListener?.stop()
        }
    }

    private func suspendDeviceWork(status: String) {
        deviceRequestGeneration &+= 1
        isApplyingDPI = false
        device = nil
        statusText = status
        syncInputListeners()
    }
}
