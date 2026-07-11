import AppKit
import Combine
import Foundation
import OSLog

final class MonitorStore: ObservableObject {
    let settings: MonitorSettings

    @Published private(set) var modules: [MonitorModule]
    @Published var selectedKind: MonitorKind = .cpu
    @Published private(set) var menuBarFrame = 0
    @Published private(set) var displayedComputeLoad = 0.0
    @Published private(set) var menuBarIconImage = MenuBarComputeRingIcon.image(
        load: 0,
        frame: 0,
        darkMode: false,
        loadLevel: .idle
    )
    @Published var isPanelVisible = false
    #if DISPLAY_CONTROL
    let displayController = DisplayControlController()
    private var brightnessKeyEventTap: BrightnessKeyEventTap?
    #endif
    let mouseController = MouseControlController()

    private var allModules: [MonitorModule]
    private let refreshSchedule = MonitorRefreshSchedule()
    private var timerCancellable: AnyCancellable?
    private var animationTimerCancellable: AnyCancellable?
    private let samplingCoordinator = SamplingCoordinator()
    private var samplingTask: Task<Void, Never>?
    private var samplingGeneration = 0
    private var cancellables: Set<AnyCancellable> = []
    private var menuBarTargetComputeLoad = 0.0
    private var framesSinceLastMenuBarTargetUpdate = MonitorConstants.menuBarLoadUpdateFrameInterval
    private var animationTickCounter = 0
    private var lastMenuBarIconKey = ""

    init() {
        let settings = MonitorSettings()
        let initialModules = MonitorKind.allCases.map(MonitorModule.placeholder)
        self.settings = settings
        allModules = initialModules
        modules = initialModules.filter { settings.isVisible($0.kind) }
        Task { [samplingCoordinator, settings] in
            await samplingCoordinator.setCodexRefreshInterval(settings.codexRefreshIntervalMinutes * 60)
            await samplingCoordinator.retainSamplers(for: settings.visibleKinds)
        }
        advance(kinds: settings.visibleKinds)
        updateMenuBarTargetComputeLoadIfNeeded(force: true)
        updateMenuBarIcon(force: true)
        refreshSchedule.markRefreshed(settings.visibleKinds, at: Date())
        #if DISPLAY_CONTROL
        displayController.settings = settings
        brightnessKeyEventTap = BrightnessKeyEventTap(settings: settings, displayController: displayController)
        configureDisplayControlServices()
        #endif
        mouseController.configure(settings: settings)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.modules = self.visibleModules(from: self.allModules)
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
        #if DISPLAY_CONTROL
        Publishers.MergeMany(
            settings.$displayModuleVisible.map { _ in () }.eraseToAnyPublisher(),
            settings.$displayBrightnessControlEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$displayVolumeControlEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$displayContrastControlEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$brightnessKeyInterceptionEnabled.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.configureDisplayControlServices()
        }
        .store(in: &cancellables)

        settings.$displaySoftwareDimmingEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.displayController.settings = self.settings
            }
            .store(in: &cancellables)
        #endif
        settings.$codexRefreshIntervalMinutes
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] minutes in
                guard let self else { return }
                Task { [samplingCoordinator = self.samplingCoordinator] in
                    await samplingCoordinator.setCodexRefreshInterval(minutes * 60)
                }
            }
            .store(in: &cancellables)
        settings.$visibleKinds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visibleKinds in
                guard let self else { return }
                Task { [samplingCoordinator = self.samplingCoordinator] in
                    await samplingCoordinator.retainSamplers(for: visibleKinds)
                }
                self.refreshSchedule.reset()
                self.modules = self.visibleModules(from: self.allModules)
                self.advance(kinds: visibleKinds)
            }
            .store(in: &cancellables)
        timerCancellable = Timer.publish(every: refreshSchedule.tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.advance()
                self?.retryBrightnessKeyTapIfNeeded()
            }
        animationTimerCancellable = Timer.publish(every: MonitorConstants.animationInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.advanceAnimation()
            }
    }

    deinit {
        samplingTask?.cancel()
        timerCancellable?.cancel()
        animationTimerCancellable?.cancel()
        cancellables.removeAll()
    }

    var selectedModule: MonitorModule {
        allModules.first { $0.kind == selectedKind }
            ?? allModules.first
            ?? MonitorModule.placeholder(kind: selectedKind)
    }

    var combinedComputeLoad: Double {
        switch settings.ringSource {
        case .combined:
            let cpuValue = allModules.first { $0.kind == .cpu }?.value ?? 0
            let gpuValue = allModules.first { $0.kind == .gpu }?.value ?? 0
            let memoryPressure = allModules.first { $0.kind == .memory }?.pressure ?? .unknown
            return ComputeLoadModel.combined(
                cpuValue: cpuValue,
                gpuValue: gpuValue,
                memoryPressure: memoryPressure
            )
        case .cpu:
            return allModules.first { $0.kind == .cpu }?.value ?? 0
        case .gpu:
            return allModules.first { $0.kind == .gpu }?.value ?? 0
        case .memory:
            return allModules.first { $0.kind == .memory }?.value ?? 0
        case .storage:
            return allModules.first { $0.kind == .storage }?.value ?? 0
        case .network:
            return allModules.first { $0.kind == .network }?.value ?? 0
        case .battery:
            return allModules.first { $0.kind == .battery }?.value ?? 0
        case .codex:
            return allModules.first { $0.kind == .codex }?.value ?? 0
        case .codexWeekly:
            return codexMetricPercent("weekly")
        }
    }

    var haloRingLoadLevel: MenuBarComputeLoadLevel {
        switch settings.ringSource {
        case .combined, .cpu, .gpu, .storage, .network, .battery:
            return ComputeLoadModel.loadLevel(for: combinedComputeLoad)
        case .codex, .codexWeekly:
            return ComputeLoadModel.quotaLevel(forRemaining: combinedComputeLoad)
        case .memory:
            let pressure = allModules.first { $0.kind == .memory }?.pressure ?? .unknown
            switch pressure {
            case .normal: return .idle
            case .warning: return .busy
            case .critical: return .stressed
            case .unknown: return .working
            }
        }
    }

    private func codexMetricPercent(_ name: String) -> Double {
        guard let value = allModules.first(where: { $0.kind == .codex })?
            .metrics
            .first(where: { $0.name == name })?
            .value
            .replacingOccurrences(of: "%", with: ""),
              let number = Double(value) else {
            return 0
        }
        return min(100, max(0, number))
    }

    private func advance() {
        let kinds = refreshSchedule.dueKinds(
            at: Date(),
            visibleKinds: settings.visibleKinds,
            panelVisible: isPanelVisible
        )
        guard !kinds.isEmpty else {
            return
        }
        advance(kinds: kinds)
    }

    private func advance(kinds: some Sequence<MonitorKind>) {
        let requestedKinds = Array(kinds)
        guard !requestedKinds.isEmpty else { return }

        samplingTask?.cancel()
        samplingGeneration &+= 1
        let requestGeneration = samplingGeneration
        let previousModules = allModules
        let coordinator = samplingCoordinator

        samplingTask = Task { [weak self] in
            let snapshot = await coordinator.sample(
                kinds: requestedKinds,
                previousModules: previousModules
            )
            guard !Task.isCancelled,
                  let snapshot,
                  let self,
                  requestGeneration == self.samplingGeneration
            else {
                return
            }
            self.allModules = snapshot.modules
            self.modules = self.visibleModules(from: snapshot.modules)
        }
    }

    private func advanceAnimation() {
        animationTickCounter += 1
        menuBarFrame = (menuBarFrame + 1) % 48
        updateMenuBarTargetComputeLoadIfNeeded(force: true)
        let nextDisplayedComputeLoad = ComputeLoadModel.smoothedDisplayValue(
            current: displayedComputeLoad,
            target: menuBarTargetComputeLoad
        )
        if abs(nextDisplayedComputeLoad - displayedComputeLoad) >= 0.01 {
            displayedComputeLoad = nextDisplayedComputeLoad
        }
        updateMenuBarIcon()
    }

    private func retryBrightnessKeyTapIfNeeded() {
        #if DISPLAY_CONTROL
        brightnessKeyEventTap?.refreshPermissionState()
        #endif
    }

    #if DISPLAY_CONTROL
    private func configureDisplayControlServices() {
        displayController.settings = settings

        if needsDisplayController {
            displayController.startAutomaticRefresh()
            if displayController.displays.isEmpty {
                displayController.refreshAsync()
            }
        } else {
            displayController.stopAutomaticRefresh()
        }

        if settings.brightnessKeyInterceptionEnabled {
            brightnessKeyEventTap?.start()
        } else {
            brightnessKeyEventTap?.stop()
        }
    }

    private var needsDisplayController: Bool {
        settings.brightnessKeyInterceptionEnabled
            || displayController.needsBuiltInBlackoutMaintenance
            || (
                settings.displayModuleVisible
                && (
                    settings.displayBrightnessControlEnabled
                    || settings.displayVolumeControlEnabled
                    || settings.displayContrastControlEnabled
                )
            )
    }
    #endif

    private func updateMenuBarTargetComputeLoadIfNeeded(force: Bool = false) {
        framesSinceLastMenuBarTargetUpdate += 1
        guard force || framesSinceLastMenuBarTargetUpdate >= MonitorConstants.menuBarLoadUpdateFrameInterval else {
            return
        }

        framesSinceLastMenuBarTargetUpdate = 0
        let currentLoad = combinedComputeLoad
        guard ComputeLoadModel.shouldUpdateMenuBarTarget(
            currentTarget: menuBarTargetComputeLoad,
            nextTarget: currentLoad
        ) else {
            return
        }

        menuBarTargetComputeLoad = currentLoad
    }

    private func updateMenuBarIcon(force: Bool = false) {
        let darkMode = NSApp.effectiveAppearance.isDark
        let loadBucket = Int(displayedComputeLoad.rounded())
        let level = haloRingLoadLevel
        let key = "\(loadBucket)-\(menuBarFrame)-\(darkMode)-\(level)"
        guard force || key != lastMenuBarIconKey else {
            return
        }
        lastMenuBarIconKey = key
        menuBarIconImage = MenuBarComputeRingIcon.image(
            load: displayedComputeLoad,
            frame: menuBarFrame,
            darkMode: darkMode,
            loadLevel: level
        )
    }

    private func visibleModules(from modules: [MonitorModule]) -> [MonitorModule] {
        modules.filter { settings.isVisible($0.kind) }
    }

    func panelDidAppear() {
        isPanelVisible = true
        refreshCodexUsageNow()
    }

    func panelDidDisappear() {
        isPanelVisible = false
    }

    func refreshCodexUsageNow() {
        guard settings.isVisible(.codex) else { return }
        refreshSchedule.markRefreshed([MonitorKind.codex], at: Date())
        let previousModules = allModules
        let coordinator = samplingCoordinator
        Task { [weak self] in
            guard let snapshot = await coordinator.refreshCodex(previousModules: previousModules),
                  let self,
                  !Task.isCancelled
            else {
                return
            }
            self.allModules = snapshot.modules
            self.modules = self.visibleModules(from: snapshot.modules)
        }
    }

    func refreshNow() {
        refreshSchedule.reset()
        advance(kinds: settings.visibleKinds)
        #if DISPLAY_CONTROL
        displayController.refreshNow()
        #endif
    }

    func moduleDetailsText() -> String {
        modules.map { module in
            let metrics = module.metrics.map { "\($0.name): \($0.value)" }.joined(separator: ", ")
            return "\(module.kind.title): \(module.summary) \(metrics)"
        }
        .joined(separator: "\n")
    }
}
