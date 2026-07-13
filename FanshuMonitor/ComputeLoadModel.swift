import Foundation

enum ComputeLoadModel {
    static func combined(
        cpuValue: Double,
        gpuValue: Double,
        memoryPressure: MemoryPressureLevel = .normal
    ) -> Double {
        let cpu = min(100, max(0, cpuValue))
        let gpu = min(100, max(0, gpuValue))
        let memory = memoryPressureScore(memoryPressure)
        return cpu * 0.4 + gpu * 0.4 + memory * 0.2
    }

    static func memoryPressureScore(_ pressure: MemoryPressureLevel) -> Double {
        switch pressure {
        case .normal:
            return 0
        case .warning:
            return 70
        case .critical:
            return 100
        case .unknown:
            return 0
        }
    }

    static func loadLevel(for load: Double) -> MenuBarComputeLoadLevel {
        switch load {
        case ..<35: return .idle
        case ..<65: return .working
        case ..<85: return .busy
        default: return .stressed
        }
    }

    static func quotaLevel(forRemaining remaining: Double) -> MenuBarComputeLoadLevel {
        switch remaining {
        case 65...: return .idle
        case 35..<65: return .working
        case 15..<35: return .busy
        default: return .stressed
        }
    }

    static func ringProgress(for value: Double) -> Double {
        min(1, max(0, value / 100))
    }

    static func smoothedDisplayValue(
        current: Double,
        target: Double,
        maxStep: Double = MonitorConstants.menuBarLoadSmoothStep
    ) -> Double {
        let clampedCurrent = min(100, max(0, current))
        let clampedTarget = min(100, max(0, target))
        let delta = clampedTarget - clampedCurrent

        if abs(delta) <= maxStep {
            return clampedTarget
        }

        return clampedCurrent + (delta > 0 ? maxStep : -maxStep)
    }

    static func shouldUpdateMenuBarTarget(
        currentTarget: Double,
        nextTarget: Double,
        threshold: Double = MonitorConstants.menuBarLoadChangeThreshold
    ) -> Bool {
        abs(min(100, max(0, nextTarget)) - min(100, max(0, currentTarget))) >= threshold
    }
}
