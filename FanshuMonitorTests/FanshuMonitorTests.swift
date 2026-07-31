//
//  FanshuMonitorTests.swift
//  FanshuMonitorTests
//
//  
//

import Foundation
import Testing
@testable import FanshuMonitor

struct FanshuMonitorTests {

    @Test func monitorSeverityCalculation() {
        #expect(MonitorSeverity.calm != .warning)
        #expect(MonitorSeverity.warning != .critical)
        #expect(MonitorSeverity.critical != .calm)
    }

    @Test func monitorKindIdentification() {
        #expect(MonitorKind.cpu.id == "cpu")
        #expect(MonitorKind.gpu.id == "gpu")
        #expect(MonitorKind.memory.id == "memory")
    }

    @Test func panelModuleTitlesUseOneCompactNamingSystem() {
        #expect(MonitorKind.cpu.panelTitle == "CPU")
        #expect(MonitorKind.gpu.panelTitle == "GPU")
        #expect(MonitorKind.memory.panelTitle == "UMA")
        #expect(MonitorKind.battery.panelTitle == "Power")
        #expect(MonitorKind.codex.panelTitle == "Codex Limits")
    }

    @Test func monitorModuleSeverityForCPU() {
        let module = MonitorModule(
            kind: .cpu,
            value: 90,
            summary: "90%",
            metrics: [],
            samples: []
        )
        #expect(module.severity == .critical)
    }

    @Test func batterySeverityUsesRawPowerTypeKey() {
        let module = MonitorModule(
            kind: .battery,
            value: 100,
            summary: "ac-power",
            metrics: [
                MonitorMetric(name: "type", value: "ac-power")
            ],
            samples: []
        )

        #expect(module.severity == .calm)
    }

    @Test func placeholderMetricNamesAreStableKeys() {
        let module = MonitorModule.placeholder(kind: .cpu)

        #expect(module.metrics.map(\.name) == ["current", "average", "peak"])
    }

    @Test func computeLoadCombinesCPUAndGPU() {
        #expect(ComputeLoadModel.combined(cpuValue: 50, gpuValue: 25) == 30)
        #expect(ComputeLoadModel.combined(cpuValue: 140, gpuValue: -20) == 40)
    }

    @Test func computeLoadIncludesMemoryPressure() {
        #expect(ComputeLoadModel.memoryPressureScore(.normal) == 0)
        #expect(ComputeLoadModel.memoryPressureScore(.warning) == 70)
        #expect(ComputeLoadModel.memoryPressureScore(.critical) == 100)
        #expect(ComputeLoadModel.memoryPressureScore(.unknown) == 0)
        #expect(ComputeLoadModel.combined(cpuValue: 50, gpuValue: 25, memoryPressure: .warning) == 44)
        #expect(ComputeLoadModel.combined(cpuValue: 50, gpuValue: 25, memoryPressure: .critical) == 50)
    }

    @Test func computeLoadDisplayValueMovesTowardTarget() {
        #expect(ComputeLoadModel.smoothedDisplayValue(current: 10, target: 50) == 50)
        #expect(ComputeLoadModel.smoothedDisplayValue(current: 50, target: 10) == 10)
        #expect(ComputeLoadModel.smoothedDisplayValue(current: 49, target: 50) == 50)
    }

    @Test func menuBarTargetIgnoresSmallComputeLoadChanges() {
        #expect(!ComputeLoadModel.shouldUpdateMenuBarTarget(currentTarget: 30, nextTarget: 34.9))
        #expect(ComputeLoadModel.shouldUpdateMenuBarTarget(currentTarget: 30, nextTarget: 35))
        #expect(ComputeLoadModel.shouldUpdateMenuBarTarget(currentTarget: 35, nextTarget: 30))
    }

    @Test func menuBarRingUsesExactPercentage() {
        #expect(ComputeLoadModel.ringProgress(for: 0) == 0)
        #expect(ComputeLoadModel.ringProgress(for: 93) == 0.93)
        #expect(ComputeLoadModel.ringProgress(for: 100) == 1)
    }

    @Test func monitorRefreshScheduleTickInterval() {
        let schedule = MonitorRefreshSchedule()
        #expect(schedule.tickInterval == 0.8)
        #expect(schedule.timerInterval(panelVisible: true) == 0.8)
        #expect(schedule.timerInterval(panelVisible: false) == 5.0)
    }

    @Test func visiblePanelUsesFastModuleSpecificRefreshIntervals() {
        let schedule = MonitorRefreshSchedule()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let kinds: Set<MonitorKind> = [.cpu, .gpu, .memory, .network, .battery]

        #expect(Set(schedule.dueKinds(
            at: start,
            visibleKinds: kinds,
            panelVisible: true
        )) == kinds)
        #expect(Set(schedule.dueKinds(
            at: start.addingTimeInterval(0.79),
            visibleKinds: kinds,
            panelVisible: true
        )).isEmpty)
        #expect(Set(schedule.dueKinds(
            at: start.addingTimeInterval(0.81),
            visibleKinds: kinds,
            panelVisible: true
        )) == [.cpu, .gpu, .memory, .network])
        #expect(Set(schedule.dueKinds(
            at: start.addingTimeInterval(2),
            visibleKinds: kinds,
            panelVisible: true
        )) == kinds)
    }

    @Test func expensiveMetricsRequireSelectionAndAVisiblePanel() {
        let visible = MonitorSamplingContext(
            enabledMetricIDs: ["temperature"],
            panelVisible: true
        )
        let hidden = MonitorSamplingContext(
            enabledMetricIDs: ["temperature"],
            panelVisible: false
        )
        let disabled = MonitorSamplingContext(
            enabledMetricIDs: [],
            panelVisible: true
        )

        #expect(visible.shouldCollectExpensiveMetric("temperature"))
        #expect(!hidden.shouldCollectExpensiveMetric("temperature"))
        #expect(!disabled.shouldCollectExpensiveMetric("temperature"))
    }

    @Test func networkSamplerOnlyPublishesEnabledMetrics() {
        let context = MonitorSamplingContext(
            enabledMetricIDs: ["upload"],
            panelVisible: false
        )

        let module = NetworkSampler().sample(previous: nil, context: context)

        #expect(module.metrics.map(\.name) == ["upload"])
    }

    @Test func codexRefreshScheduleUsesConfiguredInterval() {
        let schedule = MonitorRefreshSchedule()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        schedule.setInterval(600, for: .codex)

        #expect(schedule.dueKinds(at: start, visibleKinds: [.codex]).contains(.codex))
        #expect(!schedule.dueKinds(
            at: start.addingTimeInterval(599),
            visibleKinds: [.codex]
        ).contains(.codex))
        #expect(schedule.dueKinds(
            at: start.addingTimeInterval(600),
            visibleKinds: [.codex]
        ).contains(.codex))
    }

    @Test func networkAddressSummaryFormatsAddresses() {
        #expect(networkAddressSummary(["192.168.1.8"]) == "192.168.1.8")
        #expect(networkAddressSummary(["192.168.1.8", "2001:db8::8"]) == "192.168.1.8, 2001:db8::8")
        #expect(networkAddressSummary([]) == "--")
    }

    @Test func ddcRangeMapsHardwareMinimumToZeroPercent() {
        let range = DDCValueRange(min: 10, max: 100)

        #expect(range.percentage(from: 10) == 0)
        #expect(range.percentage(from: 100) == 100)
        #expect(range.rawValue(for: 0) == 10)
        #expect(range.rawValue(for: 100) == 100)
    }

    @Test func ddcRangeMapsMidpointInsideEffectiveRange() {
        let range = DDCValueRange(min: 10, max: 100)

        #expect(range.rawValue(for: 50) == 55)
        #expect(range.percentage(from: 55) == 50)
    }

    @Test func defaultBrightnessStepsVisitEveryFivePercentLevel() {
        var value = 0.0
        var levels: [Double] = []

        while value < 100 {
            value = BrightnessStepCalculator.nextValue(from: value, step: 5, increasing: true)
            levels.append(value)
        }

        #expect(levels == Array(stride(from: 5.0, through: 100.0, by: 5.0)))

        var descending: [Double] = []
        while value > 0 {
            value = BrightnessStepCalculator.nextValue(from: value, step: 5, increasing: false)
            descending.append(value)
        }
        #expect(descending == Array(stride(from: 95.0, through: 0.0, by: -5.0)))
    }

    @Test func brightnessStepsSnapToTheNearestDirectionalLevel() {
        #expect(BrightnessStepCalculator.nextValue(from: 46, step: 5, increasing: true) == 50)
        #expect(BrightnessStepCalculator.nextValue(from: 46, step: 5, increasing: false) == 45)
        #expect(BrightnessStepCalculator.nextValue(from: 100, step: 5, increasing: true) == 100)
        #expect(BrightnessStepCalculator.nextValue(from: 0, step: 5, increasing: false) == 0)
        #expect(!BrightnessStepCalculator.changesValue(from: 100, to: 100))
        #expect(!BrightnessStepCalculator.changesValue(from: 0, to: 0))
        #expect(BrightnessStepCalculator.changesValue(from: 95, to: 100))
    }

    @Test func everyDefaultBrightnessLevelChangesHardwareOrSoftwareDimming() {
        let levels = Array(stride(from: 0.0, through: 100.0, by: 5.0))

        for pair in zip(levels, levels.dropFirst()) {
            let previousHardware = DisplayDimmingCalibration.hardwareBrightness(forUserBrightness: pair.0)
            let nextHardware = DisplayDimmingCalibration.hardwareBrightness(forUserBrightness: pair.1)
            let previousOverlay = DisplayDimmingCalibration.overlayOpacity(forUserBrightness: pair.0)
            let nextOverlay = DisplayDimmingCalibration.overlayOpacity(forUserBrightness: pair.1)

            #expect(
                abs(nextHardware - previousHardware) > 0.001
                    || abs(nextOverlay - previousOverlay) > 0.001
            )
        }
    }

    @Test func everyDefaultBrightnessLevelChangesEvenOnLowResolutionDDC() {
        let range = DDCValueRange(min: 0, max: 10)
        let levels = Array(stride(from: 0.0, through: 100.0, by: 5.0))
        var previous: (raw: UInt16, opacity: Double)?

        for level in levels {
            let hardware = DisplayDimmingCalibration.hardwareBrightness(forUserBrightness: level)
            let plan = range.brightnessWritePlan(for: hardware)
            let baseOpacity = DisplayDimmingCalibration.overlayOpacity(forUserBrightness: level)
            let combinedOpacity = 1 - (1 - baseOpacity) * (1 - plan.overlayOpacity)

            if let previous {
                #expect(
                    plan.rawValue != previous.raw
                        || abs(combinedOpacity - previous.opacity) > 0.001
                )
            }
            previous = (plan.rawValue, combinedOpacity)
        }
    }

    @Test func ddcRangePersistsAcrossServiceRecreation() {
        let suiteName = "FanshuMonitorTests.ddcRange"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let range = DDCValueRange(min: 7, max: 83)

        DisplayDDCRangeStore(defaults: defaults).save(range, displayStorageID: "test-display")
        let restored = DisplayDDCRangeStore(defaults: defaults).range(displayStorageID: "test-display")

        #expect(restored == range)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func monitorColorSchemeDefaultsToSystemBlue() {
        let defaults = UserDefaults(suiteName: "FanshuMonitorTests.colorScheme.default")!
        defaults.removePersistentDomain(forName: "FanshuMonitorTests.colorScheme.default")

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.colorSchemePreference == .systemBlue)
    }

    @Test func monitorColorSchemeLoadsPersistedValue() {
        let defaults = UserDefaults(suiteName: "FanshuMonitorTests.colorScheme.persisted")!
        defaults.removePersistentDomain(forName: "FanshuMonitorTests.colorScheme.persisted")
        defaults.set(MonitorColorSchemePreference.rose.rawValue, forKey: "settings.colorSchemePreference")

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.colorSchemePreference == .rose)
    }

    @Test func monitorColorSchemeFallsBackForUnknownValue() {
        let defaults = UserDefaults(suiteName: "FanshuMonitorTests.colorScheme.unknown")!
        defaults.removePersistentDomain(forName: "FanshuMonitorTests.colorScheme.unknown")
        defaults.set("unknown", forKey: "settings.colorSchemePreference")

        let settings = MonitorSettings(defaults: defaults)

        #expect(settings.colorSchemePreference == .systemBlue)
    }

    @Test func codexUsagePayloadBuildsQuotaModule() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 25, "reset_at": 1779385358 },
            "secondary_window": { "used_percent": 40, "reset_at": 1779868997 }
          },
          "rate_limit_reset_credits": {
            "available_count": 2,
            "applicable_available_count": 1
          }
        }
        """

        let report = try CodexUsageClient.parseUsage(Data(json.utf8))
        let module = CodexQuotaSampler.module(from: report)

        #expect(module.kind == .codex)
        #expect(module.value == 75)
        #expect(module.summary == "Plus")
        #expect(module.metrics.first { $0.name == "five-hour" }?.value == "75%")
        #expect(module.metrics.first { $0.name == "weekly" }?.value == "60%")
        #expect(module.metrics.first { $0.name == "five-hour-reset" }?.value != nil)
        #expect(module.metrics.first { $0.name == "weekly-reset" }?.value != nil)
        #expect(module.metrics.first { $0.name == "reset-credits" }?.value == "2 张")
    }

    @Test func codexUsageClassifiesAWeeklyPrimaryWindowByDuration() throws {
        let json = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 9,
              "reset_at": 1784505468,
              "limit_window_seconds": 604800
            },
            "secondary_window": null
          }
        }
        """

        let report = try CodexUsageClient.parseUsage(Data(json.utf8))
        let module = CodexQuotaSampler.module(from: report)

        #expect(module.value == 0)
        #expect(module.metrics.first { $0.name == "five-hour" }?.value == "--")
        #expect(module.metrics.first { $0.name == "weekly" }?.value == "91%")
        #expect(module.metrics.first { $0.name == "weekly-reset" }?.value != "--")
        #expect(module.metrics.first { $0.name == "reset-credits" }?.value == "--")
    }

    @Test func codexResetCreditsMetricIsDisabledByDefault() {
        let resetCredits = MonitorKind.codex.availableMetrics.first { $0.id == "reset-credits" }

        #expect(resetCredits?.title == "重置卡")
        #expect(resetCredits?.isDefault == false)
    }

    @Test func batteryAdapterReportsDisconnectedStateWithoutStaleWattage() {
        #expect(BatterySampler.adapterMetricValue(isConnected: false, watts: 60) == "not-connected")
        #expect(BatterySampler.adapterMetricValue(isConnected: true, watts: 60) == "60 W")
        #expect(BatterySampler.adapterMetricValue(isConnected: true, watts: nil) == "--")
    }

    @Test func batteryPowerTelemetryUsesTheCorrectDirectionAndUnits() {
        #expect(BatterySampler.chargingPowerWatts(batteryPowerMilliwatts: 8_100) == 8.1)
        #expect(BatterySampler.chargingPowerWatts(batteryPowerMilliwatts: -8_100) == nil)
        #expect(BatterySampler.systemPowerWatts(
            systemLoadMilliwatts: 7_300,
            systemPowerInMilliwatts: 60_000,
            batteryPowerMilliwatts: 15_000
        ) == 7.3)
        #expect(BatterySampler.systemPowerWatts(
            systemLoadMilliwatts: nil,
            systemPowerInMilliwatts: 60_000,
            batteryPowerMilliwatts: 15_000
        ) == 45)
        #expect(BatterySampler.systemPowerWatts(
            systemLoadMilliwatts: nil,
            systemPowerInMilliwatts: 30_000,
            batteryPowerMilliwatts: -5_000
        ) == 35)
        #expect(BatterySampler.systemPowerWatts(
            systemLoadMilliwatts: nil,
            systemPowerInMilliwatts: 0,
            batteryPowerMilliwatts: -7_300
        ) == 7.3)
    }

    @Test func networkCounterResetDoesNotCreateAnOverflowSpike() {
        #expect(monotonicCounterDelta(current: 1_500, previous: 1_000) == 500)
        #expect(monotonicCounterDelta(current: 100, previous: 9_000) == 0)
    }

    @Test func hiddenPanelOnlyKeepsMenuBarRingDependenciesActive() {
        let visibleKinds: Set<MonitorKind> = [
            .cpu, .gpu, .memory, .storage, .network, .battery, .codex
        ]
        #expect(MonitorSamplingPolicy.activeKinds(
            visibleKinds: visibleKinds,
            panelVisible: false,
            ringSource: .combined
        ) == [.cpu, .gpu, .memory])
        #expect(MonitorSamplingPolicy.activeKinds(
            visibleKinds: visibleKinds,
            panelVisible: false,
            ringSource: .network
        ) == [.network])
        #expect(MonitorSamplingPolicy.activeKinds(
            visibleKinds: visibleKinds,
            panelVisible: false,
            ringSource: .codexWeekly
        ) == [.codex])
        #expect(MonitorSamplingPolicy.activeKinds(
            visibleKinds: visibleKinds,
            panelVisible: true,
            ringSource: .combined
        ) == visibleKinds)
    }

    @Test func logitechDeviceMatchingRejectsNonMouseProducts() {
        #expect(LogitechMouseDeviceMatcher.isSupported(LogitechMouseDescriptor(
            productID: 0xB037,
            productName: "MX Anywhere 3S",
            primaryUsagePage: 1,
            primaryUsage: 2
        )))
        #expect(LogitechMouseDeviceMatcher.isSupported(LogitechMouseDescriptor(
            productID: 42,
            productName: "Logitech Mouse",
            primaryUsagePage: 1,
            primaryUsage: 2
        )))
        #expect(!LogitechMouseDeviceMatcher.isSupported(LogitechMouseDescriptor(
            productID: 43,
            productName: "Logitech Keyboard",
            primaryUsagePage: 1,
            primaryUsage: 6
        )))
    }

    @Test func codexTransportTimeoutUsesResponsiveError() {
        #expect(CodexUsageClient.requestTimeout == 12)
        #expect(CodexUsageClient.mapTransportError(URLError(.timedOut)) == .networkTimedOut)
        #expect(CodexUsageError.networkTimedOut.localizedDescription == "连接超时")
    }

    @Test func codexQuotaCacheRestoresTheLastSuccessfulReport() {
        let suiteName = "FanshuMonitorTests.codexQuotaCache"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let report = CodexQuotaReport(
            planType: "plus",
            periods: [
                CodexQuotaSnapshot(
                    id: "week",
                    label: "一周",
                    remaining: 87,
                    limit: 100,
                    usedPercent: 13,
                    resetAt: nil
                )
            ],
            resetCredits: 2
        )

        CodexQuotaCache.save(report, defaults: defaults)
        let module = CodexQuotaCache.loadModule(defaults: defaults)

        #expect(module?.summary == "Plus")
        #expect(module?.metrics.first { $0.name == "weekly" }?.value == "87%")
        #expect(module?.metrics.first { $0.name == "reset-credits" }?.value == "2 张")
    }

    @Test func codexRefreshFailureKeepsTheCachedPlanAndQuota() {
        let cachedModule = MonitorModule(
            kind: .codex,
            value: 0,
            summary: "--",
            metrics: [
                MonitorMetric(name: "plan", value: "Plus"),
                MonitorMetric(name: "five-hour", value: "--"),
                MonitorMetric(name: "weekly", value: "51%"),
                MonitorMetric(name: "five-hour-reset", value: "--"),
                MonitorMetric(name: "weekly-reset", value: "2026.8.5"),
                MonitorMetric(name: "reset-credits", value: "--")
            ],
            samples: seedSamples(0)
        )

        let fallback = CodexQuotaSampler.fallbackModule(
            cachedModule: cachedModule,
            errorDescription: "连接超时"
        )

        #expect(fallback.summary == "Plus")
        #expect(fallback.metrics.first { $0.name == "plan" }?.value == "Plus")
        #expect(fallback.metrics.first { $0.name == "weekly" }?.value == "51%")
        #expect(fallback.metrics.first { $0.name == "status" }?.value == "连接超时")
    }

    @Test func codexQuotaPresentationUsesWeeklyFallbackWhenFiveHourIsMissing() {
        let presentation = CodexQuotaPresentation(metrics: [
            MonitorMetric(name: "five-hour", value: "--"),
            MonitorMetric(name: "weekly", value: "80%"),
            MonitorMetric(name: "weekly-reset", value: "2026.7.18")
        ])

        #expect(!presentation.hasFiveHourQuota)
        #expect(presentation.progressValue == 80)
        #expect(presentation.weeklyText == "80%")
        #expect(presentation.weeklyResetText == "2026.7.18")
    }

    @Test func codexQuotaPresentationRestoresFiveHourLayoutAutomatically() {
        let presentation = CodexQuotaPresentation(metrics: [
            MonitorMetric(name: "five-hour", value: "47%"),
            MonitorMetric(name: "weekly", value: "80%"),
            MonitorMetric(name: "weekly-reset", value: "2026.7.18")
        ])

        #expect(presentation.hasFiveHourQuota)
        #expect(presentation.progressValue == 47)
    }
}
