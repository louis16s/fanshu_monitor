//
//  SettingsTests.swift
//  FanshuMonitorTests
//

import Foundation
import Testing
@testable import FanshuMonitor

struct MouseHeaderPresentationTests {
    @Test func hidesBatteryWhenNoMouseIsConnected() {
        #expect(MouseHeaderPresentation.batteryText(for: nil) == nil)
    }

    @Test func presentsTheCachedBatteryWithoutStartingDeviceWork() {
        let device = LogitechMouseDevice(
            productID: 0xB037,
            productName: "MX Anywhere 3S",
            transport: "USB",
            supportsDPI: true,
            dpiMin: 200,
            dpiMax: 8000,
            currentDPI: 1600,
            batteryPercent: 95
        )

        #expect(MouseHeaderPresentation.batteryText(for: device) == "95%")
    }
}

struct SettingsTests {
    @Test func defaultThemePreference() {
        let settings = MonitorSettings()
        #expect(settings.themePreference == .system)
    }

    @Test func defaultLanguagePreference() {
        let settings = MonitorSettings()
        #expect(settings.languagePreference == .system)
    }

    @Test func defaultCodexRefreshInterval() {
        let defaults = UserDefaults(suiteName: "defaultCodexRefreshInterval")!
        defaults.removePersistentDomain(forName: "defaultCodexRefreshInterval")

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.codexRefreshIntervalMinutes == 5)
    }

    @Test func codexResetCreditsIsOptionalByDefault() {
        let suite = "codexResetCreditsIsOptionalByDefault"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let settings = MonitorSettings(defaults: defaults)

        #expect(!settings.isMetricEnabled("reset-credits", for: .codex))
    }

    @Test func codexActiveTasksAreEnabledByDefault() {
        let suite = "codexActiveTasksAreEnabledByDefault"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.isMetricEnabled("active-tasks", for: .codex))
    }

    @Test func codexRefreshIntervalLoadsPersistedValue() {
        let suite = "codexRefreshIntervalLoadsPersistedValue"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(10.0, forKey: "settings.codexRefreshIntervalMinutes")

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.codexRefreshIntervalMinutes == 10)
    }

    @Test func displayModuleIsVisibleByDefault() {
        let defaults = UserDefaults(suiteName: "displayModuleIsVisibleByDefault")!
        defaults.removePersistentDomain(forName: "displayModuleIsVisibleByDefault")

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.displayModuleVisible)
        #expect(settings.displayCapabilitiesEnabled)
    }

    @Test func displayCapabilitiesPreferencePersists() {
        let suite = "displayCapabilitiesPreferencePersists"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)

        settings.displayCapabilitiesEnabled = false

        let reloaded = MonitorSettings(defaults: defaults)
        #expect(!reloaded.displayCapabilitiesEnabled)
    }

    @Test func codexModuleAppearsForExistingVisibleModuleSettings() {
        let suite = "codexModuleAppearsForExistingVisibleModuleSettings"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["cpu", "gpu", "memory", "battery"], forKey: "settings.visibleKinds")

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.isVisible(.codex))
    }

    @Test func visibilityToggle() {
        let settings = MonitorSettings()
        settings.setVisible(false, for: .cpu)
        #expect(!settings.isVisible(.cpu))
        settings.setVisible(true, for: .cpu)
        #expect(settings.isVisible(.cpu))
    }

    @Test func metricSelectionCapsAtFourItems() {
        let defaults = UserDefaults(suiteName: "metricSelectionCapsAtFourItems")!
        defaults.removePersistentDomain(forName: "metricSelectionCapsAtFourItems")
        let settings = MonitorSettings(defaults: defaults)

        settings.setMetric("system", enabled: true, for: .cpu)
        settings.setMetric("user", enabled: true, for: .cpu)
        settings.setMetric("idle", enabled: true, for: .cpu)
        settings.setMetric("temperature", enabled: true, for: .cpu)
        settings.setMetric("temperature-status", enabled: true, for: .cpu)
        settings.setMetric("missing", enabled: true, for: .cpu)

        #expect(settings.isMetricEnabled("system", for: .cpu))
        #expect(settings.isMetricEnabled("user", for: .cpu))
        #expect(settings.isMetricEnabled("idle", for: .cpu))
        #expect(settings.isMetricEnabled("temperature", for: .cpu))
        #expect(!settings.isMetricEnabled("temperature-status", for: .cpu))
        #expect(!settings.isMetricEnabled("missing", for: .cpu))
        #expect(!settings.canEnableMetric("missing", for: .cpu))
    }

    @Test func codexMetricSelectionHasNoCountLimit() {
        let suite = "codexMetricSelectionHasNoCountLimit"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)

        for metric in MonitorKind.codex.availableMetrics {
            settings.setMetric(metric.id, enabled: true, for: .codex)
        }

        #expect(MonitorKind.codex.availableMetrics.allSatisfy {
            settings.isMetricEnabled($0.id, for: .codex)
        })
        #expect(!settings.canEnableMetric("missing", for: .codex))
        settings.setMetric("missing", enabled: true, for: .codex)
        #expect(!settings.isMetricEnabled("missing", for: .codex))
    }

    @Test func codexActiveTaskMigrationRunsOnlyOnce() {
        let suite = "codexActiveTaskMigrationRunsOnlyOnce"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["five-hour", "weekly"], forKey: "settings.enabledMetrics.codex")

        let migrated = MonitorSettings(defaults: defaults)
        #expect(migrated.isMetricEnabled("active-tasks", for: .codex))
        migrated.setMetric("active-tasks", enabled: false, for: .codex)

        let reloaded = MonitorSettings(defaults: defaults)
        #expect(!reloaded.isMetricEnabled("active-tasks", for: .codex))
    }

    @Test func memoryDefaultsShowCompressed() {
        let defaults = UserDefaults(suiteName: "memoryDefaultsShowCompressed")!
        defaults.removePersistentDomain(forName: "memoryDefaultsShowCompressed")
        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.isMetricEnabled("compressed", for: .memory))
    }

    @Test func gpuTemperatureIsOptionalByDefault() {
        let defaults = UserDefaults(suiteName: "gpuTemperatureIsOptionalByDefault")!
        defaults.removePersistentDomain(forName: "gpuTemperatureIsOptionalByDefault")
        let settings = MonitorSettings(defaults: defaults)

        #expect(!settings.isMetricEnabled("temperature", for: .gpu))
        #expect(settings.canEnableMetric("temperature", for: .gpu))
    }

    @Test func codexPlanIsNotASelectableMetric() {
        let defaults = UserDefaults(suiteName: "codexPlanIsNotASelectableMetric")!
        defaults.removePersistentDomain(forName: "codexPlanIsNotASelectableMetric")
        let settings = MonitorSettings(defaults: defaults)

        #expect(!MonitorKind.codex.availableMetrics.contains { $0.id == "plan" })
        #expect(!settings.isMetricEnabled("plan", for: .codex))
        #expect(!settings.canEnableMetric("plan", for: .codex))
        settings.setMetric("plan", enabled: true, for: .codex)
        #expect(!settings.isMetricEnabled("plan", for: .codex))
    }

    @Test func storageDefaultsIncludeDiskHealth() {
        let suite = "storageDefaultsIncludeDiskHealth"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.isMetricEnabled("health", for: .storage))
    }

    @Test func storageDiskHealthMigrationRunsOnlyOnce() {
        let suite = "storageDiskHealthMigrationRunsOnlyOnce"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["used", "free", "total"], forKey: "settings.enabledMetrics.storage")

        let migrated = MonitorSettings(defaults: defaults)
        #expect(migrated.isMetricEnabled("health", for: .storage))
        migrated.setMetric("health", enabled: false, for: .storage)

        let reloaded = MonitorSettings(defaults: defaults)
        #expect(!reloaded.isMetricEnabled("health", for: .storage))
    }

    @Test func mouseControlDefaultsAreLowOverhead() {
        let defaults = UserDefaults(suiteName: "mouseControlDefaultsAreLowOverhead")!
        defaults.removePersistentDomain(forName: "mouseControlDefaultsAreLowOverhead")
        let settings = MonitorSettings(defaults: defaults)

        #expect(!settings.mouseControlEnabled)
        #expect(settings.mouseDPIOnDemandEnabled)
        #expect(settings.mouseDPI == 1600)
        #expect(settings.mouseAction(for: .middle) == .passThrough)
        #expect(settings.mouseAction(for: .gesture) == .passThrough)
        #expect(settings.mouseAction(for: .back) == .paste)
        #expect(settings.mouseAction(for: .forward) == .launchpad)
        #expect(settings.brightnessKeyStepPercent == 5)
    }

    @Test func mouseButtonMappingLoadsPersistedValues() {
        let suite = "mouseButtonMappingLoadsPersistedValues"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "settings.mouse.controlEnabled")
        defaults.set(MouseButtonAction.copy.rawValue, forKey: "settings.mouse.action.middle")

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.mouseControlEnabled)
        #expect(settings.mouseAction(for: .middle) == .copy)
    }

    @Test func customMouseShortcutPersistsPerButton() {
        let suite = "customMouseShortcutPersistsPerButton"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = MonitorSettings(defaults: defaults)
        let shortcut = MouseKeyboardShortcut(
            keyCode: 40,
            modifiers: [.control, .option, .command],
            keyLabel: "K"
        )

        settings.setMouseAction(.customShortcut, for: .back)
        settings.setMouseCustomShortcut(shortcut, for: .back)

        let reloaded = MonitorSettings(defaults: defaults)
        #expect(reloaded.mouseMapping(for: .back) == MouseButtonMapping(
            action: .customShortcut,
            shortcut: shortcut
        ))
        #expect(shortcut.displayText == "⌃⌥⌘K")
        #expect(reloaded.mouseMapping(for: .forward).shortcut == nil)
    }
}
