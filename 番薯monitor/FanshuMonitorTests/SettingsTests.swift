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

    @Test func displayModuleIsVisibleByDefault() {
        let defaults = UserDefaults(suiteName: "displayModuleIsVisibleByDefault")!
        defaults.removePersistentDomain(forName: "displayModuleIsVisibleByDefault")

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.displayModuleVisible)
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
}
