import AppKit
import Combine
import Darwin
import Foundation
import OSLog

final class MonitorStore: ObservableObject {
    let settings: MonitorSettings

    @Published private(set) var modules: [MonitorModule]
    @Published var selectedKind: MonitorKind = .cpu
    @Published private(set) var menuBarFrame = 0
    @Published private(set) var displayedComputeLoad = 0.0
    @Published private(set) var codexTasks: [CodexTaskProgress] = []
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
    let lockScreenController = LockScreenPolicyController()
    let updateChecker = UpdateChecker()

    private var allModules: [MonitorModule]
    private let refreshSchedule = MonitorRefreshSchedule()
    private var timerCancellable: AnyCancellable?
    private var animationTimerCancellable: AnyCancellable?
    private let samplingCoordinator = SamplingCoordinator()
    private var samplingTask: Task<Void, Never>?
    private var pendingSamplingKinds: Set<MonitorKind> = []
    private var codexRefreshTask: Task<Void, Never>?
    private var codexTaskProgressTask: Task<Void, Never>?
    private var codexTaskProgressTimerCancellable: AnyCancellable?
    private let codexTaskProgressReader = CodexTaskProgressReader()
    private var samplingGeneration = 0
    private var cancellables: Set<AnyCancellable> = []
    private var menuBarTargetComputeLoad = 0.0
    private var lastMenuBarIconKey = ""
    private var terminationSignalSource: DispatchSourceSignal?

    init(settings: MonitorSettings = MonitorSettings()) {
        let initialModules = MonitorKind.allCases.map { kind in
            if kind == .codex, let cachedModule = CodexQuotaCache.loadModule() {
                return cachedModule
            }
            return MonitorModule.placeholder(kind: kind)
        }
        self.settings = settings
        refreshSchedule.setInterval(settings.codexRefreshIntervalMinutes * 60, for: .codex)
        allModules = initialModules
        modules = initialModules.filter { settings.isVisible($0.kind) }
        guard !AppRuntime.isRunningTests else {
            return
        }
        Task { [updateChecker] in
            await updateChecker.checkAutomaticallyIfNeeded(enabled: settings.updateChecksEnabled)
        }
        let initialSamplingKinds = MonitorSamplingPolicy.activeKinds(
            visibleKinds: settings.visibleKinds,
            panelVisible: false,
            ringSource: settings.ringSource
        )
        Task { [samplingCoordinator] in
            await samplingCoordinator.setCodexRefreshInterval(settings.codexRefreshIntervalMinutes * 60)
            await samplingCoordinator.retainSamplers(for: initialSamplingKinds)
        }
        advance(kinds: initialSamplingKinds)
        updateMenuBarTargetComputeLoadIfNeeded(force: true)
        updateMenuBarIcon(force: true)
        refreshSchedule.markRefreshed(settings.visibleKinds, at: Date())
        #if DISPLAY_CONTROL
        displayController.settings = settings
        brightnessKeyEventTap = BrightnessKeyEventTap(settings: settings, displayController: displayController)
        configureDisplayControlServices()
        #endif
        mouseController.configure(settings: settings)
        lockScreenController.configure(settings: settings)
        configureTerminationSignalHandler()
        #if DISPLAY_CONTROL
        Publishers.MergeMany(
            settings.$displayModuleVisible.map { _ in () }.eraseToAnyPublisher(),
            settings.$displayBrightnessControlEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$displayVolumeControlEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$displayContrastControlEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$displayCapabilitiesEnabled.map { _ in () }.eraseToAnyPublisher(),
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
                self.refreshSchedule.setInterval(minutes * 60, for: .codex)
                Task { [samplingCoordinator = self.samplingCoordinator] in
                    await samplingCoordinator.setCodexRefreshInterval(minutes * 60)
                }
            }
            .store(in: &cancellables)
        settings.$updateChecksEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard enabled, let self else { return }
                Task { [updateChecker = self.updateChecker] in
                    await updateChecker.checkAutomaticallyIfNeeded(enabled: true)
                }
            }
            .store(in: &cancellables)
        settings.$enabledMetrics
            .map { enabledMetrics in
                let defaults = Set(
                    MonitorKind.codex.availableMetrics
                        .filter(\.isDefault)
                        .map(\.id)
                )
                return (enabledMetrics[.codex] ?? defaults).contains(.activeTasks)
            }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureCodexTaskProgressMonitoring()
            }
            .store(in: &cancellables)
        settings.$ringSource
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.syncSamplerResidency()
                    if self.settings.ringSource == .network,
                       self.settings.isVisible(.network) {
                        self.advance(kinds: [MonitorKind.network])
                    }
                    self.refreshMenuBarLoad()
                }
            }
            .store(in: &cancellables)
        settings.$visibleKinds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visibleKinds in
                guard let self else { return }
                let activeKinds = self.activeSamplingKinds
                self.cancelSamplingTask()
                self.syncSamplerResidency()
                self.refreshSchedule.reset()
                self.modules = self.visibleModules(from: self.allModules)
                self.advance(kinds: activeKinds)
                self.configureCodexTaskProgressMonitoring()
                self.refreshMenuBarLoad()
            }
            .store(in: &cancellables)
        configureSamplingTimer()
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshInputServicesAfterActivation()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                #if DISPLAY_CONTROL
                self?.displayController.prepareBuiltInDisplayForTermination()
                #endif
            }
            .store(in: &cancellables)
        animationTimerCancellable = Timer.publish(every: MonitorConstants.animationInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.advanceAnimation()
            }
    }

    deinit {
        samplingTask?.cancel()
        codexRefreshTask?.cancel()
        codexTaskProgressTask?.cancel()
        codexTaskProgressTimerCancellable?.cancel()
        timerCancellable?.cancel()
        animationTimerCancellable?.cancel()
        terminationSignalSource?.cancel()
        cancellables.removeAll()
    }

    private func configureTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            #if DISPLAY_CONTROL
            self?.displayController.prepareBuiltInDisplayForTermination()
            #endif
            exit(EXIT_SUCCESS)
        }
        terminationSignalSource = source
        source.resume()
    }

    var selectedModule: MonitorModule {
        allModules.first { $0.kind == selectedKind }
            ?? allModules.first
            ?? MonitorModule.placeholder(kind: selectedKind)
    }

    var combinedComputeLoad: Double {
        switch settings.ringSource {
        case .combined:
            let cpuValue = visibleModuleValue(for: .cpu)
            let gpuValue = visibleModuleValue(for: .gpu)
            let memoryPressure = settings.isVisible(.memory)
                ? allModules.first { $0.kind == .memory }?.pressure ?? .unknown
                : .unknown
            return ComputeLoadModel.combined(
                cpuValue: cpuValue,
                gpuValue: gpuValue,
                memoryPressure: memoryPressure
            )
        case .cpu:
            return visibleModuleValue(for: .cpu)
        case .gpu:
            return visibleModuleValue(for: .gpu)
        case .memory:
            return visibleModuleValue(for: .memory)
        case .storage:
            return visibleModuleValue(for: .storage)
        case .network:
            return visibleModuleValue(for: .network)
        case .battery:
            return visibleModuleValue(for: .battery)
        case .codex:
            return visibleModuleValue(for: .codex)
        case .codexWeekly:
            return codexMetricPercent(.weekly)
        }
    }

    var haloRingLoadLevel: MenuBarComputeLoadLevel {
        switch settings.ringSource {
        case .combined, .cpu, .gpu, .storage, .network, .battery:
            return ComputeLoadModel.loadLevel(for: combinedComputeLoad)
        case .codex, .codexWeekly:
            return ComputeLoadModel.quotaLevel(forRemaining: combinedComputeLoad)
        case .memory:
            guard settings.isVisible(.memory) else {
                return .idle
            }
            let pressure = allModules.first { $0.kind == .memory }?.pressure ?? .unknown
            switch pressure {
            case .normal: return .idle
            case .warning: return .busy
            case .critical: return .stressed
            case .unknown: return .working
            }
        }
    }

    private func codexMetricPercent(_ name: MetricID) -> Double {
        guard settings.isVisible(.codex) else {
            return 0
        }
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

    private func visibleModuleValue(for kind: MonitorKind) -> Double {
        guard settings.isVisible(kind) else {
            return 0
        }
        return allModules.first { $0.kind == kind }?.value ?? 0
    }

    private func advance() {
        let kinds = refreshSchedule.dueKinds(
            at: Date(),
            visibleKinds: activeSamplingKinds,
            panelVisible: isPanelVisible
        )
        guard !kinds.isEmpty else {
            return
        }
        advance(kinds: kinds)
    }

    private func advance(
        kinds: some Sequence<MonitorKind>,
        firstPaintKinds: Set<MonitorKind> = []
    ) {
        var requestedKinds = Array(Set(kinds))
        if requestedKinds.contains(.codex) {
            requestedKinds.removeAll { $0 == .codex }
            refreshCodexUsage(force: false)
        }
        guard !requestedKinds.isEmpty else { return }

        guard samplingTask == nil else {
            pendingSamplingKinds.formUnion(requestedKinds)
            return
        }

        samplingGeneration &+= 1
        let requestGeneration = samplingGeneration
        let enabledMetrics = enabledSamplingMetrics(for: requestedKinds)
        let panelVisible = isPanelVisible
        let coordinator = samplingCoordinator
        let previousModules = allModules

        samplingTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: MonitorModule?.self) { group in
                for kind in requestedKinds {
                    let previous = previousModules.first { $0.kind == kind }
                    let metricIDs = enabledMetrics[kind] ?? []
                    let mode: MonitorSamplingMode = firstPaintKinds.contains(kind)
                        ? .firstPaint
                        : .routine
                    group.addTask {
                        await coordinator.sampleModule(
                            kind: kind,
                            previous: previous,
                            enabledMetricIDs: metricIDs,
                            panelVisible: panelVisible,
                            mode: mode
                        )
                    }
                }

                for await module in group {
                    guard !Task.isCancelled,
                          let module,
                          requestGeneration == self.samplingGeneration
                    else {
                        group.cancelAll()
                        return
                    }
                    self.mergeSampledModule(module)
                }
            }

            guard requestGeneration == self.samplingGeneration else { return }
            self.samplingTask = nil
            let pendingKinds = self.pendingSamplingKinds
            self.pendingSamplingKinds.removeAll()
            if !pendingKinds.isEmpty {
                self.advance(kinds: pendingKinds)
            }
        }
    }

    private func mergeSampledModule(_ module: MonitorModule) {
        guard let index = allModules.firstIndex(where: { $0.kind == module.kind })
        else {
            return
        }
        allModules[index] = module
        modules = visibleModules(from: allModules)
        refreshMenuBarLoad()
    }

    private func advanceAnimation() {
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

    private func refreshInputServicesAfterActivation() {
        #if DISPLAY_CONTROL
        brightnessKeyEventTap?.refreshPermissionState()
        #endif
        mouseController.refreshButtonTapIfPossible()
    }

    #if DISPLAY_CONTROL
    private func configureDisplayControlServices() {
        displayController.settings = settings

        if needsDisplayController {
            displayController.startAutomaticRefresh()
            if displayController.displays.isEmpty {
                displayController.refreshAsync()
            } else {
                displayController.refreshNow()
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
                    || settings.displayCapabilitiesEnabled
                )
            )
    }
    #endif

    private func updateMenuBarTargetComputeLoadIfNeeded(force: Bool = false) {
        let currentLoad = combinedComputeLoad
        guard force || ComputeLoadModel.shouldUpdateMenuBarTarget(
            currentTarget: menuBarTargetComputeLoad,
            nextTarget: currentLoad
        ) else {
            return
        }

        menuBarTargetComputeLoad = currentLoad
    }

    private func refreshMenuBarLoad() {
        updateMenuBarTargetComputeLoadIfNeeded(force: true)
        displayedComputeLoad = menuBarTargetComputeLoad
        updateMenuBarIcon(force: true)
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
        guard !isPanelVisible else { return }
        isPanelVisible = true
        cancelSamplingTask()
        #if DISPLAY_CONTROL
        displayController.setPanelVisible(true)
        #endif
        syncSamplerResidency()
        configureSamplingTimer()
        let visibleKinds = settings.visibleKinds
        refreshSchedule.markRefreshed(visibleKinds, at: Date())
        if visibleKinds.contains(.codex) {
            refreshCodexUsage(force: true)
        }
        let immediatelyVisibleKinds = visibleKinds.filter { $0 != .codex }
        let firstPaintKinds: Set<MonitorKind> = visibleKinds.contains(.battery) ? [.battery] : []
        advance(kinds: immediatelyVisibleKinds, firstPaintKinds: firstPaintKinds)
        if !firstPaintKinds.isEmpty {
            // The first battery pass publishes power flow before slower health
            // details. Queue one full pass immediately behind it.
            advance(kinds: firstPaintKinds)
        }
        configureCodexTaskProgressMonitoring()
    }

    func panelDidDisappear() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        cancelSamplingTask()
        #if DISPLAY_CONTROL
        displayController.setPanelVisible(false)
        #endif
        syncSamplerResidency()
        configureSamplingTimer()
        configureCodexTaskProgressMonitoring()
    }

    private var activeSamplingKinds: Set<MonitorKind> {
        MonitorSamplingPolicy.activeKinds(
            visibleKinds: settings.visibleKinds,
            panelVisible: isPanelVisible,
            ringSource: settings.ringSource
        )
    }

    private func syncSamplerResidency() {
        let activeKinds = activeSamplingKinds
        Task { [samplingCoordinator] in
            await samplingCoordinator.retainSamplers(for: activeKinds)
        }
    }

    private func cancelSamplingTask() {
        samplingTask?.cancel()
        samplingTask = nil
        pendingSamplingKinds.removeAll()
        samplingGeneration &+= 1
    }

    private func refreshCodexUsage(force: Bool) {
        guard settings.isVisible(.codex) else { return }
        refreshSchedule.markRefreshed([MonitorKind.codex], at: Date())
        let previousModules = allModules
        let coordinator = samplingCoordinator
        codexRefreshTask?.cancel()
        codexRefreshTask = Task { [weak self] in
            guard let snapshot = await coordinator.refreshCodex(
                previousModules: previousModules,
                force: force
            ),
                  let self,
                  !Task.isCancelled
            else {
                return
            }
            self.allModules = snapshot.modules
            self.modules = self.visibleModules(from: snapshot.modules)
            self.refreshCodexTaskProgress()
        }
    }

    private func configureCodexTaskProgressMonitoring() {
        codexTaskProgressTimerCancellable?.cancel()
        codexTaskProgressTimerCancellable = nil
        codexTaskProgressTask?.cancel()
        codexTaskProgressTask = nil

        guard isPanelVisible,
              settings.isVisible(.codex),
              settings.isMetricEnabled(.activeTasks, for: .codex) else {
            clearCodexTaskProgress()
            return
        }
        refreshCodexTaskProgress()
        codexTaskProgressTimerCancellable = Timer.publish(
            every: 2,
            tolerance: 0.4,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            self?.refreshCodexTaskProgress()
        }
    }

    private func refreshCodexTaskProgress() {
        guard isPanelVisible,
              settings.isVisible(.codex),
              settings.isMetricEnabled(.activeTasks, for: .codex) else {
            return
        }
        codexTaskProgressTask?.cancel()
        codexTaskProgressTask = Task { [weak self] in
            guard let self else { return }
            let tasks = await codexTaskProgressReader.load()
            guard !Task.isCancelled else { return }
            applyCodexTaskProgress(tasks)
        }
    }

    private func applyCodexTaskProgress(_ tasks: [CodexTaskProgress]) {
        guard settings.isMetricEnabled(.activeTasks, for: .codex) else {
            clearCodexTaskProgress()
            return
        }
        guard codexTasks != tasks else { return }
        codexTasks = tasks
    }

    private func clearCodexTaskProgress() {
        guard !codexTasks.isEmpty else { return }
        codexTasks = []
    }

    private func enabledSamplingMetrics(
        for kinds: some Sequence<MonitorKind>
    ) -> [MonitorKind: Set<MetricID>] {
        Dictionary(uniqueKeysWithValues: kinds.map { kind in
            let metricIDs = settings.enabledMetrics[kind]
                ?? Set(kind.availableMetrics.filter(\.isDefault).map(\.id))
            return (kind, metricIDs)
        })
    }

    private func configureSamplingTimer() {
        timerCancellable?.cancel()
        let interval = refreshSchedule.timerInterval(panelVisible: isPanelVisible)
        timerCancellable = Timer.publish(
            every: interval,
            tolerance: max(0.1, interval * 0.1),
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            self?.advance()
        }
    }

    func moduleDetailsText() -> String {
        modules.map { module in
            let metrics = module.metrics.map { "\($0.name): \($0.value)" }.joined(separator: ", ")
            return "\(module.kind.title): \(module.summary) \(metrics)"
        }
        .joined(separator: "\n")
    }
}
