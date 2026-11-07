import AppKit
import Combine
import Foundation

@MainActor
final class MouseControlController: ObservableObject {
    @Published private(set) var device: LogitechMouseDevice?
    @Published private var deviceStatus: MouseDeviceStatus = .disabled
    @Published private var buttonStatus: MouseButtonListenerStatus = .disabled
    @Published private(set) var isApplyingDPI = false
    func combinedStatusLine(locale: Locale) -> String {
        guard settings?.mouseControlEnabled == true else {
            return deviceStatus.localized(locale: locale)
        }
        let summary: String
        if case .deviceReady = deviceStatus, let device {
            let dpi = device.currentDPI.map { " · \($0) DPI" } ?? ""
            summary = device.displayName(locale: locale) + dpi
        } else {
            summary = deviceStatus.localized(locale: locale)
        }
        let battery = device?.batteryPercent.map {
            " · \(MouseLocalization.string("mouse.status.battery", locale: locale)) \($0)%"
        } ?? ""
        return "\(buttonStatus.localized(locale: locale)) · \(summary)\(battery)"
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
        deviceStatus = .disabled
        buttonStatus = .disabled
    }

    func refreshIfNeeded() {
        guard settings?.mouseControlEnabled == true else { return }
        if isMousePresent {
            refresh(readDPI: true)
        } else {
            presenceMonitor.refresh()
            probeDevicePresence()
        }
    }

    func refreshButtonTapIfPossible() {
        guard settings?.mouseControlEnabled == true else { return }
        syncInputListeners()
    }

    func refresh() {
        guard settings?.mouseControlEnabled == true else { return }
        deviceStatus = .detecting
        if isMousePresent {
            refresh(readDPI: true)
        } else {
            presenceMonitor.refresh()
            probeDevicePresence()
        }
    }

    private func refresh(readDPI: Bool) {
        guard settings?.mouseControlEnabled == true else {
            suspendDeviceWork(status: .disabled)
            return
        }
        guard isMousePresent else {
            suspendDeviceWork(status: .waitingForDevice)
            return
        }

        deviceStatus = .detecting
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
                self.deviceStatus = .deviceReady
                self.syncInputListeners()
            } else {
                self.suspendDeviceWork(status: .waitingForDevice)
            }
        }
    }

    func applyDPI(_ value: Int) {
        guard settings?.mouseControlEnabled == true, device != nil else { return }
        let clamped = min(8000, max(200, value))
        deviceRequestGeneration &+= 1
        let requestGeneration = deviceRequestGeneration
        isApplyingDPI = true
        deviceStatus = .applyingDPI
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
                self.deviceStatus = .deviceReady
            } else {
                self.deviceStatus = .dpiApplyFailed
            }
        }
    }

    private func syncEnabledState(_ enabled: Bool) {
        if enabled {
            presenceSessionGeneration &+= 1
            let sessionGeneration = presenceSessionGeneration
            deviceStatus = .detecting
            buttonStatus = .waitingForDevice
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
            suspendDeviceWork(status: .disabled)
        }
    }

    private func mousePresenceDidChange(_ isPresent: Bool) {
        guard settings?.mouseControlEnabled == true else { return }
        isMousePresent = isPresent
        if isPresent {
            refresh(readDPI: !(settings?.mouseDPIOnDemandEnabled ?? true))
        } else {
            suspendDeviceWork(status: .waitingForDevice)
            probeDevicePresence()
        }
    }

    private func probeDevicePresence() {
        let requestGeneration = deviceRequestGeneration
        let sessionGeneration = presenceSessionGeneration
        Task { [weak self, mouseWorker] in
            let isPresent = await mouseWorker.hasDevice()
            guard let self,
                  requestGeneration == self.deviceRequestGeneration,
                  sessionGeneration == self.presenceSessionGeneration,
                  self.settings?.mouseControlEnabled == true else {
                return
            }
            guard isPresent else { return }
            self.isMousePresent = true
            self.refresh(readDPI: !(self.settings?.mouseDPIOnDemandEnabled ?? true))
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
            buttonStatus = mouseControlEnabled ? .waitingForDevice : .disabled
            return
        }

        if eventTap?.start() == true {
            buttonStatus = .enabled
        } else {
            buttonStatus = .waitingForAccessibility
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

    private func suspendDeviceWork(status: MouseDeviceStatus) {
        deviceRequestGeneration &+= 1
        isApplyingDPI = false
        device = nil
        deviceStatus = status
        syncInputListeners()
    }
}

private enum MouseDeviceStatus {
    case disabled, detecting, waitingForDevice, deviceReady, applyingDPI, dpiApplyFailed

    func localized(locale: Locale) -> String {
        let key: String
        switch self {
        case .disabled: key = "mouse.status.disabled"
        case .detecting: key = "mouse.status.detecting"
        case .waitingForDevice: key = "mouse.status.waiting-device"
        case .deviceReady: key = "mouse.status.ready"
        case .applyingDPI: key = "mouse.status.applying-dpi"
        case .dpiApplyFailed: key = "mouse.status.dpi-failed"
        }
        return MouseLocalization.string(key, locale: locale)
    }
}

private enum MouseButtonListenerStatus {
    case disabled, waitingForDevice, enabled, waitingForAccessibility

    func localized(locale: Locale) -> String {
        let key: String
        switch self {
        case .disabled: key = "mouse.status.disabled"
        case .waitingForDevice: key = "mouse.status.waiting-device"
        case .enabled: key = "mouse.status.listener-enabled"
        case .waitingForAccessibility: key = "mouse.status.waiting-accessibility"
        }
        return MouseLocalization.string(key, locale: locale)
    }
}
