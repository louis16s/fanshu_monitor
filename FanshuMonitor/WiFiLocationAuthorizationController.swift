import AppKit
import CoreLocation
import Foundation

nonisolated final class WiFiAuthorizationState: @unchecked Sendable {
    static let shared = WiFiAuthorizationState()

    private let lock = NSLock()
    private var rawStatus = CLAuthorizationStatus.notDetermined.rawValue

    private init() {}

    func update(_ status: CLAuthorizationStatus) {
        lock.lock()
        rawStatus = status.rawValue
        lock.unlock()
    }

    var canReadSSID: Bool {
        lock.lock()
        let status = CLAuthorizationStatus(rawValue: rawStatus)
        lock.unlock()
        return status == .authorizedAlways
    }

    var needsAuthorizationRequest: Bool {
        lock.lock()
        let status = CLAuthorizationStatus(rawValue: rawStatus)
        lock.unlock()
        return status == .notDetermined
    }

    var unavailableMetricValue: String? {
        lock.lock()
        let status = CLAuthorizationStatus(rawValue: rawStatus)
        lock.unlock()
        if status == .authorizedAlways {
            return nil
        }
        if status == .notDetermined {
            return String(localized: "network.ssid.waiting-for-permission")
        }
        return String(localized: "network.ssid.location-required")
    }
}

final class WiFiLocationAuthorizationController: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var requestPending = false
    var authorizationDidChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        WiFiAuthorizationState.shared.update(manager.authorizationStatus)
    }

    @discardableResult
    func requestIfNeeded(activateApp: Bool = false) -> Bool {
        guard manager.authorizationStatus == .notDetermined else { return false }
        guard !requestPending else { return true }
        requestPending = true
        if activateApp, !NSApp.isActive {
            NSApp.activate()
        }
        DispatchQueue.main.async { [weak self] in
            // A menu-bar app can continue sampling after its popover closes.
            // macOS reports successful location authorization as Always, and
            // CoreWLAN requires that privilege before exposing an SSID.
            self?.manager.requestAlwaysAuthorization()
        }
        return true
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        requestPending = false
        WiFiAuthorizationState.shared.update(manager.authorizationStatus)
        authorizationDidChange?(manager.authorizationStatus)
    }
}
