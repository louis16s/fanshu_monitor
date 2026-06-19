//
//  SettingsTests.swift
//  FanshuMonitorTests
//

import Foundation
import Testing
@testable import FanshuMonitor

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

    @Test func memoryDefaultsShowCompressed() {
        let defaults = UserDefaults(suiteName: "memoryDefaultsShowCompressed")!
        defaults.removePersistentDomain(forName: "memoryDefaultsShowCompressed")
        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.isMetricEnabled("compressed", for: .memory))
    }

    @Test func codexPlanIsOptionalByDefault() {
        let defaults = UserDefaults(suiteName: "codexPlanIsOptionalByDefault")!
        defaults.removePersistentDomain(forName: "codexPlanIsOptionalByDefault")
        let settings = MonitorSettings(defaults: defaults)

        #expect(!settings.isMetricEnabled("plan", for: .codex))
        #expect(settings.canEnableMetric("plan", for: .codex))
        settings.setMetric("plan", enabled: true, for: .codex)
        #expect(settings.isMetricEnabled("plan", for: .codex))
        settings.setMetric("plan", enabled: false, for: .codex)
        #expect(!settings.isMetricEnabled("plan", for: .codex))
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
}
