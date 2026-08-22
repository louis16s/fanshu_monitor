import AppKit
import Combine
import CoreLocation
import Darwin
import Foundation
import OSLog

@MainActor
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
    let displayController = DisplayControlController()
    private var brightnessKeyEventTap: BrightnessKeyEventTap?
    let mouseController = MouseControlController()
    let lockScreenController = LockScreenPolicyController()
    let updateChecker = UpdateChecker()
    private let wiFiLocationAuthorizationController = WiFiLocationAuthorizationController()

    private var allModules: [MonitorModule]
    private let refreshSchedule = MonitorRefreshSchedule()
    private var timerCancellable: AnyCancellable?
    private var animationTimerCancellable: AnyCancellable?
    private let samplingCoordinator = SamplingCoordinator()
    private var samplingTasks: [MonitorKind: Task<Void, Never>] = [:]
    private var samplerResidencyTask: Task<Void, Never>?
    private var codexRefreshTask: Task<Void, Never>?
    private var codexTaskProgressTask: Task<Void, Never>?
    private var codexTaskProgressTimerCancellable: AnyCancellable?
    private let codexTaskProgressReader = CodexTaskProgressReader()
    private var samplingGeneration = 0
    private var cancellables: Set<AnyCancellable> = []
    private var menuBarTargetComputeLoad = 0.0
    private var lastMenuBarIconKey = ""
    private var terminationSignalSource: DispatchSourceSignal?
    private var lastEnabledMetricsSnapshot: [MonitorKind: Set<MetricID>] = [:]

    init(settings: MonitorSettings? = nil) {
        let settings = settings ?? MonitorSettings()
        let initialModules = MonitorKind.allCases.map { kind in
            if kind == .codex, let cachedModule = CodexQuotaCache.loadModule() {
                return cachedModule
            }
            if kind == .storage, settings.isVisible(.storage) {
                return StorageSampler.bootstrapModule()
            }
            return MonitorModule.placeholder(kind: kind)
        }
        self.settings = settings
        lastEnabledMetricsSnapshot = settings.enabledMetrics
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
        displayController.settings = settings
        brightnessKeyEventTap = BrightnessKeyEventTap(settings: settings, displayController: displayController)
        configureDisplayControlServices()
        mouseController.configure(settings: settings)
        lockScreenController.configure(settings: settings)
        wiFiLocationAuthorizationController.authorizationDidChange = { [weak self] status in
            guard status == .authorizedAlways else { return }
            self?.advance(kinds: [MonitorKind.network])
        }
        configureTerminationSignalHandler()
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
                    self.configureSamplingTimer()
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
                self.requestWiFiAuthorizationIfNeeded()
                let activeKinds = self.activeSamplingKinds
                self.cancelSamplingTask()
                self.syncSamplerResidency()
                self.configureSamplingTimer()
                self.refreshSchedule.reset()
                self.modules = self.visibleModules(from: self.allModules)
                self.advance(kinds: activeKinds)
                self.configureCodexTaskProgressMonitoring()
                self.refreshMenuBarLoad()
            }
            .store(in: &cancellables)
        settings.$enabledMetrics
            .map { metrics in
                (metrics[.network] ?? Set(
                    MonitorKind.network.availableMetrics.filter(\.isDefault).map(\.id)
                )).contains("ssid")
            }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.requestWiFiAuthorizationIfNeeded()
            }
            .store(in: &cancellables)
        settings.$enabledMetrics
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMetrics in
                guard let self else { return }
                let changedKinds = self.changedMetricKinds(from: newMetrics)
                guard !changedKinds.isEmpty else { return }
                self.cancelSamplingTask()
                self.refreshSchedule.reset(changedKinds)
                self.advance(kinds: self.activeSamplingKinds.intersection(changedKinds))
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
                self?.displayController.prepareForTermination()
            }
            .store(in: &cancellables)
        animationTimerCancellable = Timer.publish(every: MonitorConstants.animationInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.advanceAnimation()
            }
    }

    deinit {
        samplingTasks.values.forEach { $0.cancel() }
        samplingTasks.removeAll()
        samplerResidencyTask?.cancel()
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
            self?.displayController.prepareForTermination()
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

        let enabledMetrics = enabledSamplingMetrics(for: requestedKinds)
        let panelVisible = isPanelVisible
        if panelVisible,
           requestedKinds.contains(.network),
           enabledMetrics[.network]?.contains("ssid") == true {
            wiFiLocationAuthorizationController.requestIfNeeded()
        }
        let coordinator = samplingCoordinator
        let previousModules = allModules
        let requestGeneration = samplingGeneration

        for kind in requestedKinds where samplingTasks[kind] == nil {
            let previous = previousModules.first { $0.kind == kind }
            let metricIDs = enabledMetrics[kind] ?? []
            let mode: MonitorSamplingMode = firstPaintKinds.contains(kind)
                ? .firstPaint
                : .routine

            samplingTasks[kind] = Task { [weak self] in
                let module = await coordinator.sampleModule(
                    kind: kind,
                    previous: previous,
                    enabledMetricIDs: metricIDs,
                    panelVisible: panelVisible,
                    mode: mode
                )
                guard let self else { return }

                // A canceled generation must not touch the task or schedule
                // belonging to a newer request for the same module.
                guard requestGeneration == self.samplingGeneration else { return }
                self.samplingTasks[kind] = nil
                if !Task.isCancelled, let module {
                    self.mergeSampledModule(module)
                    self.refreshSchedule.markRefreshed([kind], at: Date())
                } else {
                    self.refreshSchedule.markFailed([kind])
                }
            }
        }
    }

    private func mergeSampledModule(_ module: MonitorModule) {
        guard let index = allModules.firstIndex(where: { $0.kind == module.kind })
        else {
            return
        }
        let previousLoad = combinedComputeLoad
        allModules[index] = module
        modules = visibleModules(from: allModules)
        if abs(previousLoad - combinedComputeLoad) >= 0.01 {
            refreshMenuBarLoad()
        }
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
        brightnessKeyEventTap?.refreshPermissionState()
        mouseController.refreshButtonTapIfPossible()
    }

    private func requestWiFiAuthorizationIfNeeded(activateApp: Bool = false) {
        guard settings.isVisible(.network),
              settings.isMetricEnabled("ssid", for: .network) else { return }
        wiFiLocationAuthorizationController.requestIfNeeded(activateApp: activateApp)
    }

    func requestWiFiAuthorizationFromForeground() {
        requestWiFiAuthorizationIfNeeded(activateApp: true)
    }

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

    func setPanelVisible(_ isVisible: Bool) {
        if isVisible {
            panelDidAppear()
        } else {
            panelDidDisappear()
        }
    }

    private func panelDidAppear() {
        guard !isPanelVisible else { return }
        isPanelVisible = true
        requestWiFiAuthorizationIfNeeded(activateApp: true)
        cancelSamplingTask()
        displayController.setPanelVisible(true)
        syncSamplerResidency()
        configureSamplingTimer()
        let visibleKinds = settings.visibleKinds
        refreshSchedule.markRefreshed(visibleKinds, at: Date())
        if visibleKinds.contains(.codex) {
            refreshCodexUsage(force: true)
        }
        let immediatelyVisibleKinds = visibleKinds.filter { $0 != .codex }
        // Root capacity is cheap, while disk health and external-volume scans
        // can take seconds. Battery telemetry is also cheap and must run in the
        // routine pass immediately so USB-PD input changes reach the animation
        // without waiting for storage diagnostics.
        let firstPaintKinds = visibleKinds.intersection([.storage])
        advance(kinds: immediatelyVisibleKinds, firstPaintKinds: firstPaintKinds)
        configureCodexTaskProgressMonitoring()
    }

    private func panelDidDisappear() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        cancelSamplingTask()
        displayController.setPanelVisible(false)
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
        samplerResidencyTask?.cancel()
        samplerResidencyTask = Task { [samplingCoordinator] in
            await samplingCoordinator.retainSamplers(for: activeKinds)
        }
    }

    private func changedMetricKinds(
        from newMetrics: [MonitorKind: Set<MetricID>]
    ) -> Set<MonitorKind> {
        let allKinds = Set(lastEnabledMetricsSnapshot.keys).union(newMetrics.keys)
        let changedKinds = Set(allKinds.filter {
            lastEnabledMetricsSnapshot[$0] != newMetrics[$0]
        })
        lastEnabledMetricsSnapshot = newMetrics
        return changedKinds
    }

    private func cancelSamplingTask() {
        samplingTasks.values.forEach { $0.cancel() }
        samplingTasks.removeAll()
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
        timerCancellable = nil
        guard isPanelVisible || !activeSamplingKinds.isEmpty else {
            return
        }
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
