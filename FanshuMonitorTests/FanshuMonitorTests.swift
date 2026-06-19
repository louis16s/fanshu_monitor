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

    @Test func monitorRefreshScheduleTickInterval() {
        let schedule = MonitorRefreshSchedule()
        #expect(schedule.tickInterval == 1.0)
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
    }
}
