//
//  FanshuMonitorTests.swift
//  FanshuMonitorTests
//
//  
//

import Foundation
import Testing
@testable import FanshuMonitor

@MainActor
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

    @Test func batterySeverityUsesProductionPowerStatus() {
        let charging = MonitorModule(
            kind: .battery,
            value: 5,
            summary: "5%",
            metrics: [
                MonitorMetric(name: "type", value: "battery"),
                MonitorMetric(name: "status", value: "charging")
            ],
            samples: []
        )
        let discharging = MonitorModule(
            kind: .battery,
            value: 5,
            summary: "5%",
            metrics: [
                MonitorMetric(name: "type", value: "battery"),
                MonitorMetric(name: "status", value: "on-battery")
            ],
            samples: []
        )

        #expect(charging.severity == .calm)
        #expect(discharging.severity == .critical)
    }

    @Test func coreModulePlaceholdersMatchTheirPanelMetrics() {
        let cpu = MonitorModule.placeholder(kind: .cpu)
        let gpu = MonitorModule.placeholder(kind: .gpu)
        let memory = MonitorModule.placeholder(kind: .memory)
        let power = MonitorModule.placeholder(kind: .battery)

        #expect(cpu.summary == "0%")
        #expect(cpu.metrics.map(\.name) == ["system", "user", "idle", "temperature"])
        #expect(gpu.summary == "0%")
        #expect(gpu.metrics.map(\.name) == ["gpu-memory", "allocated", "render", "temperature", "tiler"])
        #expect(memory.summary == "0%")
        #expect(memory.metrics.map(\.name) == ["used", "pressure", "compressed", "app-memory", "cached", "total"])
        #expect(power.summary == "0%")
        #expect(power.metrics.first { $0.name == "power" }?.value == "--")
    }

    @Test func aLateCodexRefreshCannotReplaceFreshHardwareModules() {
        var current = MonitorKind.allCases.map { MonitorModule.placeholder(kind: $0) }
        let freshCPU = MonitorModule(
            kind: .cpu,
            value: 37,
            summary: "37%",
            metrics: [],
            samples: seedSamples(37)
        )
        let freshMemory = MonitorModule(
            kind: .memory,
            value: 61,
            summary: "61%",
            metrics: [],
            samples: seedSamples(61)
        )
        current = MonitorModuleMergePolicy.replacing(freshCPU, in: current)
        current = MonitorModuleMergePolicy.replacing(freshMemory, in: current)

        var refreshedCodex = MonitorModule.placeholder(kind: .codex)
        refreshedCodex.summary = "Plus"
        let merged = MonitorModuleMergePolicy.replacing(refreshedCodex, in: current)

        #expect(merged.first { $0.kind == .cpu }?.value == 37)
        #expect(merged.first { $0.kind == .memory }?.value == 61)
        #expect(merged.first { $0.kind == .codex }?.summary == "Plus")
    }

    @Test func displayIdentityRecoverySelectsOnlyABuiltInCandidate() {
        let recovered = DisplayControlService.firstBuiltInDisplayID(
            in: [3, 1, 7],
            isBuiltIn: { $0 == 1 }
        )

        #expect(recovered == 1)
        #expect(DisplayControlService.firstBuiltInDisplayID(
            in: [3, 7],
            isBuiltIn: { _ in false }
        ) == nil)
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
        )) == kinds)
        #expect(Set(schedule.dueKinds(
            at: start.addingTimeInterval(2),
            visibleKinds: kinds,
            panelVisible: true
        )) == kinds)
    }

    @Test func resettingSelectedKindsDoesNotDisturbOtherRefreshReservations() {
        let schedule = MonitorRefreshSchedule()
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        _ = schedule.dueKinds(
            at: start,
            visibleKinds: [.cpu, .gpu],
            panelVisible: true
        )
        schedule.reset([.cpu])

        #expect(schedule.dueKinds(
            at: start.addingTimeInterval(0.1),
            visibleKinds: [.cpu, .gpu],
            panelVisible: true
        ) == [.cpu])
    }

    @Test func failedRefreshIsEligibleAgainWithoutWaitingForFullInterval() {
        let schedule = MonitorRefreshSchedule()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(schedule.dueKinds(at: start, visibleKinds: [.cpu]) == [.cpu])
        schedule.markFailed([.cpu])
        #expect(schedule.dueKinds(
            at: start.addingTimeInterval(0.01),
            visibleKinds: [.cpu]
        ) == [.cpu])
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

    @Test func firstPaintSamplingOnlyAppliesToAVisiblePanel() {
        let visible = MonitorSamplingContext(
            enabledMetricIDs: [],
            panelVisible: true,
            mode: .firstPaint
        )
        let hidden = MonitorSamplingContext(
            enabledMetricIDs: [],
            panelVisible: false,
            mode: .firstPaint
        )

        #expect(visible.prioritizesFirstPaint)
        #expect(!hidden.prioritizesFirstPaint)
        #expect(BatterySamplingPolicy.shouldCollectTelemetry(context: visible))
        #expect(!BatterySamplingPolicy.shouldCollectSmartDetails(context: visible))
        #expect(!BatterySamplingPolicy.shouldCollectTelemetry(context: hidden))
    }

    @Test func smartBatteryDetailsRequireAVisibleEnabledMetric() {
        let disabled = MonitorSamplingContext(
            enabledMetricIDs: [],
            panelVisible: true
        )
        let enabled = MonitorSamplingContext(
            enabledMetricIDs: ["health"],
            panelVisible: true
        )
        let hidden = MonitorSamplingContext(
            enabledMetricIDs: ["health"],
            panelVisible: false
        )

        #expect(!BatterySamplingPolicy.shouldCollectSmartDetails(context: disabled))
        #expect(BatterySamplingPolicy.shouldCollectSmartDetails(context: enabled))
        #expect(!BatterySamplingPolicy.shouldCollectSmartDetails(context: hidden))
    }

    @Test func networkSamplerOnlyPublishesEnabledMetrics() {
        let context = MonitorSamplingContext(
            enabledMetricIDs: ["upload"],
            panelVisible: false
        )

        let module = NetworkSampler().sample(previous: nil, context: context)

        #expect(module.metrics.map(\.name) == ["upload"])
    }

    @Test func diskHealthIsOnDemandAndCached() {
        let reads = ThreadSafeCounter()
        let sampler = StorageSampler(healthReader: {
            reads.increment()
            return "normal"
        })
        let hiddenContext = MonitorSamplingContext(
            enabledMetricIDs: ["health"],
            panelVisible: false
        )
        let visibleContext = MonitorSamplingContext(
            enabledMetricIDs: ["health"],
            panelVisible: true
        )

        let hidden = sampler.sample(previous: nil, context: hiddenContext)
        #expect(reads.value == 0)
        #expect(hidden.metrics.first { $0.name == "health" }?.value == "--")

        let firstVisible = sampler.sample(previous: hidden, context: visibleContext)
        let secondVisible = sampler.sample(previous: firstVisible, context: visibleContext)
        #expect(reads.value == 1)
        #expect(secondVisible.metrics.first { $0.name == "health" }?.value == "normal")
    }

    @Test func storageFirstPaintDoesNotWaitForHealth() {
        let reads = ThreadSafeCounter()
        let sampler = StorageSampler(healthReader: {
            reads.increment()
            return "normal"
        })
        let context = MonitorSamplingContext(
            enabledMetricIDs: ["health"],
            panelVisible: true,
            mode: .firstPaint
        )

        let module = sampler.sample(previous: nil, context: context)

        #expect(reads.value == 0)
        #expect(module.summary != "--")
        #expect(module.metrics.first { $0.name == "health" }?.value == "--")
    }

    @Test func storageBootstrapPublishesCapacityImmediately() {
        let module = StorageSampler.bootstrapModule()

        #expect(module.summary != "--")
        #expect(module.summary != "无法读取")
        #expect(module.value > 0)
        #expect(module.metrics.first { $0.name == "total" }?.value != nil)
    }

    @Test func networkSSIDUsesSelectedInterfaceAndRetriesFailures() {
        let reads = ThreadSafeCounter()
        let sampler = NetworkSampler(
            ssidReader: { _ in
                reads.increment()
                return reads.value == 1 ? nil : "Fanshu Wi-Fi"
            },
            nowProvider: {
                Date(timeIntervalSince1970: Double(reads.value * 4))
            }
        )
        let context = MonitorSamplingContext(
            enabledMetricIDs: ["ssid"],
            panelVisible: true
        )

        let first = sampler.sample(previous: nil, context: context)
        #expect(first.metrics.first { $0.name == "ssid" }?.value != "Fanshu Wi-Fi")
        let second = sampler.sample(previous: first, context: context)
        #expect(second.metrics.first { $0.name == "ssid" }?.value == "Fanshu Wi-Fi")
        #expect(reads.value == 2)
    }

    @Test func diskHealthParsesSMARTStatus() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["SMARTStatus": "Verified"],
            format: .xml,
            options: 0
        )

        #expect(DiskHealthReader.status(fromPropertyList: data) == "normal")
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

    @Test func gammaFactorOnlyDimsBelowTheHardwareFloor() {
        #expect(DisplayDimmingCalibration.gammaFactor(forUserBrightness: 100) == 1)
        #expect(DisplayDimmingCalibration.gammaFactor(forUserBrightness: 15) == 1)
        #expect(abs(DisplayDimmingCalibration.gammaFactor(forUserBrightness: 0) - 0.3) < 0.0001)
        #expect(
            DisplayDimmingCalibration.gammaFactor(forUserBrightness: 5)
                < DisplayDimmingCalibration.gammaFactor(forUserBrightness: 10)
        )
    }

    @Test func gammaFactorIncludesDDCQuantizationCorrection() {
        let base = DisplayDimmingCalibration.gammaFactor(forUserBrightness: 10)
        let corrected = DisplayDimmingCalibration.gammaFactor(
            forUserBrightness: 10,
            additionalOverlayOpacity: 0.2
        )

        #expect(corrected < base)
        #expect(corrected >= 0)
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

    @Test func appearanceOptionsAreFocusedAndMigrateRemovedThemes() {
        #expect(AppLanguagePreference.allCases == [.system, .simplifiedChinese, .english])
        #expect(MonitorColorSchemePreference.allCases.count == 4)
        #expect(MonitorColorSchemePreference.allCases.contains(.aurora))
        #expect(MonitorColorSchemePreference.allCases.allSatisfy { $0.previewColors.count == 4 })
        #expect(MonitorColorSchemePreference.migratedValue("teal") == .aurora)
        #expect(MonitorColorSchemePreference.migratedValue("nightVoyage") == .systemBlue)
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
        let localizedTitle = String(localized: "metric.codex.reset-credits")

        #expect(!localizedTitle.isEmpty)
        #expect(resetCredits?.title == localizedTitle)
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

    @Test func batteryPowerFlowKeepsInputSystemAndSignedBatteryValuesSeparate() {
        let charging = BatteryPowerTelemetry(
            adapterInputMilliwatts: 31_880,
            systemLoadMilliwatts: 5_417,
            batteryMilliwatts: 26_463
        )
        #expect(charging.adapterInputWatts == 31.88)
        #expect(charging.systemLoadWatts == 5.417)
        #expect(charging.batteryWatts == 26.463)
        #expect(charging.resolvedSystemLoadWatts == 5.417)
        #expect(BatteryPowerTelemetry.batteryFlowText(charging.batteryWatts) == "+26.5 W")

        let discharging = BatteryPowerTelemetry(
            adapterInputMilliwatts: 0,
            systemLoadMilliwatts: nil,
            batteryMilliwatts: -7_300
        )
        #expect(discharging.resolvedSystemLoadWatts == 7.3)
        #expect(BatteryPowerTelemetry.batteryFlowText(discharging.batteryWatts) == "-7.3 W")
    }

    @Test func batteryPowerFlowMetricsAreOptional() {
        let metrics = Dictionary(uniqueKeysWithValues: MonitorKind.battery.availableMetrics.map { ($0.id, $0) })

        #expect(metrics["power-flow"]?.isDefault == false)
        #expect(metrics["adapter-input"] == nil)
        #expect(metrics["system-load"] == nil)
        #expect(metrics["battery-flow"] == nil)
    }

    @Test func batteryPowerFlowOptionResolvesItsThreePanelMetrics() {
        let resolved = MonitorKind.battery.resolvedPanelMetricIDs(from: ["power-flow", "health"])

        #expect(resolved.contains("power-flow"))
        #expect(resolved.contains("health"))
        #expect(MonitorKind.batteryPowerFlowComponentIDs.isSubset(of: resolved))
        #expect(MonitorKind.cpu.resolvedPanelMetricIDs(from: ["system"]) == ["system"])
    }

    @Test func batteryPowerFlowPresentationTracksAllocationAndDirection() {
        let charging = BatteryPowerFlowPresentation(
            metrics: [
                MonitorMetric(name: "adapter-input", value: "30.0 W"),
                MonitorMetric(name: "system-load", value: "10.0 W"),
                MonitorMetric(name: "battery-flow", value: "+20.0 W")
            ],
            isConnectedToPower: true
        )
        #expect(charging.systemFraction == 1.0 / 3.0)
        #expect(charging.batteryFraction == 2.0 / 3.0)
        #expect(charging.batteryIsSupplying == false)
        #expect(charging.hasActiveFlow)

        let discharging = BatteryPowerFlowPresentation(
            metrics: [
                MonitorMetric(name: "adapter-input", value: "--"),
                MonitorMetric(name: "system-load", value: "7.3 W"),
                MonitorMetric(name: "battery-flow", value: "-7.3 W")
            ],
            isConnectedToPower: false
        )
        #expect(discharging.batteryIsSupplying)
        #expect(discharging.systemFraction == 1)
        #expect(discharging.batteryFraction == 1)
    }

    @Test func batteryPowerFlowPresentationRejectsUnavailableValues() {
        let presentation = BatteryPowerFlowPresentation(
            metrics: [
                MonitorMetric(name: "adapter-input", value: "--"),
                MonitorMetric(name: "system-load", value: "--"),
                MonitorMetric(name: "battery-flow", value: "--")
            ],
            isConnectedToPower: true
        )
        #expect(presentation.adapterInputWatts == nil)
        #expect(presentation.systemLoadWatts == nil)
        #expect(presentation.batteryWatts == nil)
        #expect(presentation.hasActiveFlow == false)
    }

    @Test func batteryPowerKeepsTheLastKnownGoodValueDuringTransientFailures() {
        #expect(BatterySampler.stableSystemPowerWatts(
            fresh: 10.374,
            cached: 8.2,
            previousMetric: "7.1 W"
        ) == 10.374)
        #expect(BatterySampler.stableSystemPowerWatts(
            fresh: nil,
            cached: 8.2,
            previousMetric: "7.1 W"
        ) == 8.2)
        #expect(BatterySampler.stableSystemPowerWatts(
            fresh: 0,
            cached: nil,
            previousMetric: "7.1 W"
        ) == 7.1)
        #expect(BatterySampler.stableSystemPowerWatts(
            fresh: .nan,
            cached: 0,
            previousMetric: "0.0 W"
        ) == nil)
    }

    @Test func networkCounterResetDoesNotCreateAnOverflowSpike() {
        #expect(monotonicCounterDelta(current: 1_500, previous: 1_000) == 500)
        #expect(monotonicCounterDelta(current: 100, previous: 9_000) == 0)
    }

    @Test func networkSamplerPrefersTheSystemPrimaryInterface() {
        let totals: [String: (input: UInt64, output: UInt64)] = [
            "en0": (100, 100),
            "bridge0": (10_000, 10_000)
        ]

        #expect(selectedNetworkInterface(primary: "en0", totals: totals) == "en0")
        #expect(selectedNetworkInterface(primary: "utun4", totals: totals) == "bridge0")
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

    @Test func standardMouseButtonsDoNotDependOnHIDPPDetection() {
        #expect(MouseInputListenerPolicy.shouldRunEventTap(
            mouseControlEnabled: true,
            devicePresent: true
        ))
        #expect(!MouseInputListenerPolicy.shouldRunEventTap(
            mouseControlEnabled: true,
            devicePresent: false
        ))
        #expect(!MouseInputListenerPolicy.shouldRunEventTap(
            mouseControlEnabled: false,
            devicePresent: true
        ))
        #expect(!MouseInputListenerPolicy.shouldRunHIDPPGesture(
            mouseControlEnabled: true,
            devicePresent: false,
            mapping: MouseButtonMapping(action: .commandTab, shortcut: nil)
        ))
        #expect(MouseInputListenerPolicy.shouldRunHIDPPGesture(
            mouseControlEnabled: true,
            devicePresent: true,
            mapping: MouseButtonMapping(action: .commandTab, shortcut: nil)
        ))
        #expect(!MouseInputListenerPolicy.shouldRunHIDPPGesture(
            mouseControlEnabled: true,
            devicePresent: true,
            mapping: MouseButtonMapping(action: .passThrough, shortcut: nil)
        ))
        #expect(!MouseInputListenerPolicy.shouldRunHIDPPGesture(
            mouseControlEnabled: true,
            devicePresent: true,
            mapping: MouseButtonMapping(action: .customShortcut, shortcut: nil)
        ))
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
        #expect(presentation.fiveHourText == "47%")
    }

    @Test func codexQuotaPresentationIdentifiesAWeeklyFallback() {
        let presentation = CodexQuotaPresentation(metrics: [
            MonitorMetric(name: "five-hour", value: "--"),
            MonitorMetric(name: "weekly", value: "80%")
        ])

        #expect(!presentation.hasFiveHourQuota)
        #expect(presentation.hasWeeklyQuota)
    }

    @Test func codexTaskProgressReadsEveryActiveConversationTitle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionDirectory = root.appendingPathComponent("2026/08/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstID = "019eba2a-524c-7c01-b14c-d378a9a01924"
        let secondID = "019f7105-186e-71c3-a3a8-8f5621029630"
        let firstRollout = sessionDirectory.appendingPathComponent("rollout-current-\(firstID).jsonl")
        let secondRollout = sessionDirectory.appendingPathComponent("rollout-current-\(secondID).jsonl")
        let firstRecords: [[String: Any]] = [
            [
                "type": "event_msg",
                "payload": ["type": "task_started", "turn_id": "turn-1"]
            ],
            [
                "type": "response_item",
                "payload": [
                    "type": "custom_tool_call",
                    "name": "exec",
                    "input": "const r = await tools.update_plan({plan:[{step:\"备份\",status:\"completed\"},{step:\"显示控制\",status:\"in_progress\"},{step:\"构建\",status:\"pending\"}]});"
                ]
            ]
        ]
        let secondRecords: [[String: Any]] = [[
            "type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "turn-2"]
        ]]
        let firstData = try firstRecords
            .map { try JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { result, record in
                result.append(record)
                result.append(0x0A)
            }
        let secondData = try secondRecords
            .map { try JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { result, record in
                result.append(record)
                result.append(0x0A)
            }
        try firstData.write(to: firstRollout)
        try secondData.write(to: secondRollout)

        let sessionIndex = root.appendingPathComponent("session_index.jsonl")
        let indexRecords = [
            "{\"id\":\"\(firstID)\",\"thread_name\":\"番薯monitor\"}",
            "{\"id\":\"\(secondID)\",\"thread_name\":\"构建 CF 博客\"}"
        ].joined(separator: "\n") + "\n"
        try indexRecords.write(to: sessionIndex, atomically: true, encoding: .utf8)

        let reader = CodexTaskProgressReader(sessionsRoot: root, sessionIndexURL: sessionIndex)
        let tasks = await reader.load()
        #expect(Set(tasks.map(\.title)) == ["番薯monitor", "构建 CF 博客"])
        let firstTask = tasks.first { $0.id == firstID }
        #expect(firstTask?.completedSteps == 1)
        #expect(firstTask?.totalSteps == 3)
        #expect(firstTask?.activeStep == "显示控制")
        #expect(Int(firstTask?.percent?.rounded() ?? -1) == 33)

        let completion = try JSONSerialization.data(withJSONObject: [
            "type": "event_msg",
            "payload": ["type": "task_complete", "turn_id": "turn-1"]
        ])
        let handle = try FileHandle(forWritingTo: firstRollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: completion)
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()

        let remainingTasks = await reader.load()
        #expect(remainingTasks.map(\.title) == ["构建 CF 博客"])
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}
