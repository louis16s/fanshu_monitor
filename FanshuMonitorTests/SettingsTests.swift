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

    @Test func metricSelectionCapsAtFiveItems() {
        let defaults = UserDefaults(suiteName: "metricSelectionCapsAtFiveItems")!
        defaults.removePersistentDomain(forName: "metricSelectionCapsAtFiveItems")
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
        #expect(settings.isMetricEnabled("temperature-status", for: .cpu))
        #expect(!settings.isMetricEnabled("missing", for: .cpu))
        #expect(!settings.canEnableMetric("missing", for: .cpu))
    }

    @Test func memoryDefaultsShowCompressed() {
        let defaults = UserDefaults(suiteName: "memoryDefaultsShowCompressed")!
        defaults.removePersistentDomain(forName: "memoryDefaultsShowCompressed")
        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.isMetricEnabled("compressed", for: .memory))
    }
}
