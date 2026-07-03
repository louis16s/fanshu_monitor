import AppKit
import Combine
import Foundation

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

        settings.$mouseGestureAction
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                self?.syncGestureListener(enabled: settings.mouseControlEnabled, action: action)
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
        refresh(readDPI: true)
    }

    private func refresh(readDPI: Bool) {
        guard settings?.mouseControlEnabled == true else {
            device = nil
            statusText = "未启用"
            return
        }

        statusText = "正在检测鼠标"
        Task { [weak self, hidService] in
            let result = await Task.detached(priority: .utility) {
                hidService.detectDevice(readDPI: readDPI)
            }.value
            guard let self else { return }
            self.device = result
            if let result {
                if let currentDPI = result.currentDPI {
                    self.settings?.mouseDPI = Double(currentDPI)
                }
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
                self.settings?.mouseDPI = Double(clamped)
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
            syncGestureListener(enabled: true, action: settings?.mouseGestureAction ?? .passThrough)
            refresh(readDPI: !(settings?.mouseDPIOnDemandEnabled ?? true))
        } else {
            eventTap?.stop()
            hidButtonListener?.stop()
            device = nil
            statusText = "未启用"
            buttonStatusText = "未启用"
        }
    }

    private func syncGestureListener(enabled: Bool, action: MouseButtonAction) {
        if enabled && action != .passThrough {
            hidButtonListener?.start()
        } else {
            hidButtonListener?.stop()
        }
    }
}
