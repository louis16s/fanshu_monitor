import Combine
import Foundation
import OSLog
import ServiceManagement

@MainActor
extension MonitorSettings {
        func setupBindings() {
            $launchAtLogin
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persistLaunchAtLogin(newValue)
                }
                .store(in: &cancellables)
    
            $themePreference
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue.rawValue, forKey: Keys.themePreference)
                }
                .store(in: &cancellables)
    
            $languagePreference
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue.rawValue, forKey: Keys.languagePreference)
                }
                .store(in: &cancellables)
    
            $colorSchemePreference
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue.rawValue, forKey: Keys.colorSchemePreference)
                }
                .store(in: &cancellables)
    
            $ringSource
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue.rawValue, forKey: Keys.ringSource)
                }
                .store(in: &cancellables)
    
            $showBuiltInDisplays
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.showBuiltInDisplays)
                }
                .store(in: &cancellables)
    
            $displayModuleVisible
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.displayModuleVisible)
                }
                .store(in: &cancellables)
    
            $displayBrightnessControlEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.displayBrightnessControlEnabled)
                }
                .store(in: &cancellables)
    
            $displayVolumeControlEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.displayVolumeControlEnabled)
                }
                .store(in: &cancellables)
    
            $displayContrastControlEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.displayContrastControlEnabled)
                }
                .store(in: &cancellables)
    
            $displayAvailabilityHintsEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.displayAvailabilityHintsEnabled)
                }
                .store(in: &cancellables)
    
            $displayCapabilitiesEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.displayCapabilitiesEnabled)
                }
                .store(in: &cancellables)
    
            $displayNativeOSDEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.displayNativeOSDEnabled)
                }
                .store(in: &cancellables)
    
            $displaySoftwareDimmingEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.displaySoftwareDimmingEnabled)
                }
                .store(in: &cancellables)
    
            $brightnessKeyStepPercent
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(min(20, max(1, newValue)), forKey: Keys.brightnessKeyStepPercent)
                }
                .store(in: &cancellables)
    
            $codexRefreshIntervalMinutes
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(min(60, max(1, newValue)), forKey: Keys.codexRefreshIntervalMinutes)
                }
                .store(in: &cancellables)
    
            $codexHeaderDetailPreference
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue.rawValue, forKey: Keys.codexHeaderDetailPreference)
                }
                .store(in: &cancellables)
    
            $updateChecksEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.updateChecksEnabled)
                }
                .store(in: &cancellables)
    
            $brightnessKeyInterceptionEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.brightnessKeyInterceptionEnabled)
                }
                .store(in: &cancellables)
    
            $mouseControlEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.mouseControlEnabled)
                }
                .store(in: &cancellables)
    
            $mouseDPIOnDemandEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.mouseDPIOnDemandEnabled)
                }
                .store(in: &cancellables)
    
            $mouseDPI
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(min(8000, max(200, newValue)), forKey: Keys.mouseDPI)
                }
                .store(in: &cancellables)
    
            $mouseMiddleAction
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue.rawValue, forKey: Keys.mouseMiddleAction)
                }
                .store(in: &cancellables)
    
            $mouseBackAction
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue.rawValue, forKey: Keys.mouseBackAction)
                }
                .store(in: &cancellables)
    
            $mouseForwardAction
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue.rawValue, forKey: Keys.mouseForwardAction)
                }
                .store(in: &cancellables)
    
            $mouseGestureAction
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue.rawValue, forKey: Keys.mouseGestureAction)
                }
                .store(in: &cancellables)
    
            $mouseCustomShortcuts
                .dropFirst()
                .sink { [weak self] newValue in
                    let storedShortcuts = Dictionary(
                        uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) }
                    )
                    guard let data = PreferencesCodec.encode(storedShortcuts, key: Keys.mouseCustomShortcuts) else { return }
                    self?.persist(data, forKey: Keys.mouseCustomShortcuts)
                }
                .store(in: &cancellables)
    
            $lockScreenPoliciesEnabled
                .dropFirst()
                .sink { [weak self] newValue in
                    self?.persist(newValue, forKey: Keys.lockScreenPoliciesEnabled)
                }
                .store(in: &cancellables)
    
            $lockScreenPolicies
                .dropFirst()
                .sink { [weak self] newValue in
                    guard let data = PreferencesCodec.encode(newValue, key: Keys.lockScreenPolicies) else { return }
                    self?.persist(data, forKey: Keys.lockScreenPolicies)
                }
                .store(in: &cancellables)
    
            $visibleKinds
                .dropFirst()
                .sink { [weak self] newValue in
                    let values = newValue.map(\.rawValue)
                    self?.persist(values, forKey: Keys.visibleKinds)
                }
                .store(in: &cancellables)
    
            $enabledMetrics
                .dropFirst()
                .sink { [weak self] newValue in
                    guard let self else { return }
                    for (kind, ids) in newValue {
                        let key = Keys.enabledMetricsPrefix + kind.rawValue
                        self.persist(ids.map(\.rawValue).sorted(), forKey: key)
                    }
                }
                .store(in: &cancellables)
        }
    
        func persist<T>(_ value: T, forKey key: String) {
            defaults.set(value, forKey: key)
        }
    
        func persistLaunchAtLogin(_ newValue: Bool) {
            guard !isUpdatingLaunchAtLogin else { return }
            updateLaunchAtLogin(newValue)
        }
    
        func updateLaunchAtLogin(_ newValue: Bool) {
            defaults.set(newValue, forKey: Keys.launchAtLoginDesired)
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                refreshLaunchAtLoginStatus()
            } catch {
                AppLogger.settings.error(
                    "Unable to update launch-at-login status: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                isUpdatingLaunchAtLogin = true
                launchAtLogin = SMAppService.mainApp.status == .enabled
                isUpdatingLaunchAtLogin = false
                defaults.set(launchAtLogin, forKey: Keys.launchAtLoginDesired)
            }
        }
}
