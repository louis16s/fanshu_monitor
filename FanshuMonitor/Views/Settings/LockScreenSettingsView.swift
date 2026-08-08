import SwiftUI

struct LockScreenSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @ObservedObject var controller: LockScreenPolicyController
    @State private var systemIdleMinutesText = "10"
    @State private var systemRequirePassword = true
    @State private var systemPasswordDelayText = "0"
    @State private var systemApplyTask: Task<Void, Never>?
    @State private var isSyncingSystemSettings = false
    @State private var systemSettingsExpanded = false
    @State private var showsRestoreConfirmation = false
    @State private var dropTargetPolicyID: LockScreenPolicy.ID?

    var body: some View {
        SettingsPage(
            showsScrollIndicators: needsScrollIndicators,
            sectionSpacing: 14,
            topPadding: 18,
            bottomPadding: 18
        ) {
            SettingsGroup("系统锁屏设置") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("直接锁定")
                            .font(.body.weight(.medium))
                        Text("屏保 \(systemIdleDescription) · 密码 \(systemPasswordDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "lock.fill")
                        .foregroundStyle(Color.accentColor)

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            systemSettingsExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: systemSettingsExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help(systemSettingsExpanded ? "收起系统锁屏设置" : "展开系统锁屏设置")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 50)

                if systemSettingsExpanded {
                    SettingsDivider()

                    SettingsRow(title: "屏保启动时间", subtitle: "与关闭显示器时间分开") {
                        HStack(spacing: 6) {
                            TextField("分钟", text: $systemIdleMinutesText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 58)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .disabled(settings.lockScreenPoliciesEnabled)
                            Text("分钟")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsDivider()

                    SettingsRow(title: "要求密码") {
                        Toggle("", isOn: $systemRequirePassword)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(settings.lockScreenPoliciesEnabled)
                    }

                    if systemRequirePassword {
                        SettingsDivider()

                        SettingsRow(title: "密码延迟", subtitle: "屏保启动后多久要求密码") {
                            HStack(spacing: 6) {
                                TextField("秒", text: $systemPasswordDelayText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 58)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .disabled(settings.lockScreenPoliciesEnabled)
                                Text("秒")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    SettingsDivider()

                    HStack {
                        Text(settings.lockScreenPoliciesEnabled ? "时间策略启用时会覆盖系统设置" : "更改后自动保存到系统")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button {
                            controller.refreshSystemSettings()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("重新读取系统设置")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            SettingsGroup("自动锁屏") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动锁屏")
                            .font(.body.weight(.medium))
                        Text(controller.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 10)

                    Image(systemName: lockStatusIcon)
                        .foregroundStyle(lockStatusColor)

                    if settings.lockScreenPoliciesEnabled {
                        Button {
                            showsRestoreConfirmation = true
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("恢复原来的系统锁屏设置")
                    }

                    Toggle("", isOn: policyMasterBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 50)
            }

            lockScreenPolicySection

        }
        .onAppear {
            controller.refreshSystemSettings()
            syncSystemSettings(controller.systemSettings)
        }
        .onChange(of: controller.systemSettings) { _, newValue in
            syncSystemSettings(newValue)
        }
        .onChange(of: systemIdleMinutesText) { scheduleSystemSettingsApply() }
        .onChange(of: systemRequirePassword) { scheduleSystemSettingsApply() }
        .onChange(of: systemPasswordDelayText) { scheduleSystemSettingsApply() }
        .confirmationDialog(
            "恢复系统锁屏设置",
            isPresented: $showsRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复并关闭自动锁屏", role: .destructive) {
                controller.restoreOriginalSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将关闭所有时间策略，并恢复启用前的系统屏保设置")
        }
        .onDisappear {
            systemApplyTask?.cancel()
            applySystemSettingsIfValid()
        }
    }

    @ViewBuilder
    private var lockScreenPolicySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("锁屏时间")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            if settings.lockScreenPolicies.isEmpty {
                SettingsGroup {
                    ContentUnavailableView {
                        Label("还没有锁屏时间", systemImage: "clock.badge.plus")
                    } description: {
                        Text("添加一条时间后，打开上方自动锁屏即可生效")
                    } actions: {
                        Button("添加锁屏时间") {
                            settings.addLockScreenPolicy()
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 20)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(settings.lockScreenPolicies.enumerated()), id: \.element.id) { index, policy in
                        LockScreenPolicyEditor(
                            index: index,
                            policy: policy,
                            settings: settings,
                            isActive: controller.activePolicy?.id == policy.id
                        )
                        .background(
                            .quaternary.opacity(0.48),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    dropTargetPolicyID == policy.id
                                        ? Color.accentColor.opacity(0.9)
                                        : Color(nsColor: .separatorColor).opacity(0.22),
                                    lineWidth: dropTargetPolicyID == policy.id ? 2 : 1
                                )
                        }
                        .dropDestination(for: String.self) { identifiers, _ in
                            guard let identifier = identifiers.first,
                                  let sourceID = UUID(uuidString: identifier) else {
                                return false
                            }
                            withAnimation(.easeInOut(duration: 0.16)) {
                                settings.moveLockScreenPolicy(id: sourceID, to: policy.id)
                            }
                            dropTargetPolicyID = nil
                            return true
                        } isTargeted: { isTargeted in
                            if isTargeted {
                                dropTargetPolicyID = policy.id
                            } else if dropTargetPolicyID == policy.id {
                                dropTargetPolicyID = nil
                            }
                        }
                    }

                    if settings.lockScreenPolicies.count < MonitorSettings.maximumLockScreenPolicies {
                        Button {
                            settings.addLockScreenPolicy()
                        } label: {
                            Label("添加锁屏时间", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 6)
                    }
                }

                Text("输入后自动保存 · 25:00 表示次日 01:00 · 最晚 40:00")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var systemIdleDescription: String {
        guard let minutes = controller.systemSettings.idleMinutes else { return "系统默认" }
        guard minutes > 0 else { return "已关闭" }
        return "\(minutes) 分钟"
    }

    private var needsScrollIndicators: Bool {
        systemSettingsExpanded
            || settings.lockScreenPolicies.count > 2
            || settings.lockScreenPolicies.contains {
                $0.dayScope == .custom || !$0.hasValidTimeRange
            }
    }

    private var lockStatusIcon: String {
        switch controller.status {
        case .locking, .locked:
            "lock.fill"
        case .lockFailed, .systemSettingsBlocked, .environmentFailed:
            "exclamationmark.triangle.fill"
        case .active:
            "clock.badge.checkmark.fill"
        case .restored:
            "arrow.uturn.backward.circle.fill"
        case .systemSettingsChanged:
            "checkmark.circle.fill"
        case .disabled, .noRules, .waiting, .waitingForPower, .waitingForPowerSource, .sessionInactive:
            "clock"
        }
    }

    private var lockStatusColor: Color {
        switch controller.status {
        case .lockFailed, .systemSettingsBlocked, .environmentFailed:
            .orange
        case .active, .locking, .locked, .restored, .systemSettingsChanged:
            Color.accentColor
        case .disabled, .noRules, .waiting, .waitingForPower, .waitingForPowerSource, .sessionInactive:
            .secondary
        }
    }

    private var policyMasterBinding: Binding<Bool> {
        Binding(
            get: { settings.lockScreenPoliciesEnabled },
            set: { settings.setLockScreenPoliciesEnabled($0) }
        )
    }

    private var systemPasswordDescription: String {
        controller.systemSettings.passwordDelayText
    }

    private func syncSystemSettings(_ systemSettings: ScreenSaverLockBaseline) {
        systemApplyTask?.cancel()
        isSyncingSystemSettings = true
        if let minutes = systemSettings.idleMinutes {
            systemIdleMinutesText = String(minutes)
        }
        if let requiresPassword = systemSettings.askForPassword {
            systemRequirePassword = requiresPassword
        }
        if let delay = systemSettings.askForPasswordDelay {
            systemPasswordDelayText = String(delay)
        }
        DispatchQueue.main.async {
            isSyncingSystemSettings = false
        }
    }

    private func scheduleSystemSettingsApply() {
        guard !isSyncingSystemSettings, !settings.lockScreenPoliciesEnabled else { return }
        systemApplyTask?.cancel()
        systemApplyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            applySystemSettingsIfValid()
        }
    }

    private func applySystemSettingsIfValid() {
        guard !settings.lockScreenPoliciesEnabled,
              let idleMinutes = Int(systemIdleMinutesText),
              (1...1_440).contains(idleMinutes),
              let passwordDelaySeconds = Int(systemPasswordDelayText),
              (0...86_400).contains(passwordDelaySeconds) else {
            return
        }
        controller.applySystemSettings(
            idleMinutes: idleMinutes,
            requirePassword: systemRequirePassword,
            passwordDelaySeconds: passwordDelaySeconds
        )
    }
}

private struct LockScreenPolicyEditor: View {
    private enum EditorField: Hashable {
        case name
        case start
        case end
        case idle
    }

    let index: Int
    let policy: LockScreenPolicy
    @ObservedObject var settings: MonitorSettings
    let isActive: Bool
    @State private var nameText = ""
    @State private var idleMinutesText = ""
    @State private var startTimeText = ""
    @State private var endTimeText = ""
    @State private var nameSaveTask: Task<Void, Never>?
    @State private var idleSaveTask: Task<Void, Never>?
    @State private var conflictFlashTask: Task<Void, Never>?
    @State private var conflictFlashVisible = false
    @FocusState private var focusedField: EditorField?
    @State private var previousFocusedField: EditorField?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("时间段名称", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.weight(.medium))
                    .frame(width: 112)
                    .focused($focusedField, equals: .name)
                    .onSubmit {
                        saveName()
                        focusedField = nil
                    }
                    .help("自定义时间段名称")

                Spacer(minLength: 4)

                HStack(spacing: 7) {
                    Picker("日期", selection: dayScopeBinding) {
                        ForEach(LockScreenDayScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 72)

                    timeField(text: $startTimeText, field: .start)

                    Text("至")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    timeField(text: $endTimeText, field: .end)

                    Toggle(isOn: isEnabledBinding) {
                        Image(systemName: policy.isEnabled ? "pause.circle" : "play.circle")
                            .frame(width: 16, height: 16)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(policy.isEnabled ? "暂停此时间段" : "启用此时间段")
                    .accessibilityLabel(policy.isEnabled ? "暂停此时间段" : "启用此时间段")

                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .padding(4)
                        .draggable(policy.id.uuidString) {
                            Label(
                                policy.name.isEmpty ? fallbackName : policy.name,
                                systemImage: "line.3.horizontal"
                            )
                            .padding(8)
                        }
                        .help("拖动卡片调整顺序")
                        .accessibilityLabel("调整\(policy.name.isEmpty ? fallbackName : policy.name)顺序")

                    Button(role: .destructive) {
                        settings.removeLockScreenPolicy(id: policy.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除这条锁屏时间")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 44)

            SettingsDivider()

            SettingsRow(title: "闲置后锁屏") {
                HStack(spacing: 6) {
                    TextField("分钟", text: $idleMinutesText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($focusedField, equals: .idle)
                        .onSubmit {
                            saveIdleMinutes()
                            focusedField = nil
                        }
                    Text("分钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: idleStatusIcon)
                        .foregroundStyle(idleStatusColor)
                        .help(idleStatusText)

                    Picker("电源条件", selection: powerConditionBinding) {
                        ForEach(LockScreenPowerCondition.allCases) { condition in
                            Label(condition.title, systemImage: condition.symbolName)
                                .tag(condition)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 104)
                }
            }

            if policy.dayScope == .custom {
                CustomDaysSettingsRow(selected: policy.customWeekdays) { weekday in
                    update { $0.toggleCustomWeekday(weekday) }
                }
            }

            if !policy.hasValidTimeRange {
                SettingsDivider()
                Text("开始和结束时间不能相同")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !conflictingPolicies.isEmpty {
                SettingsDivider()
                Label(conflictText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(policy.isEnabled ? 1 : 0.56)
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.red.opacity(conflictFlashVisible ? 0.12 : 0))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.red.opacity(conflictFlashVisible ? 0.95 : 0), lineWidth: 2)
            }
            .shadow(
                color: Color.red.opacity(conflictFlashVisible ? 0.28 : 0),
                radius: 6
            )
            .allowsHitTesting(false)
        }
        .onAppear { syncEditorText() }
        .onChange(of: policy.name) { _, newValue in
            if focusedField != .name {
                nameText = newValue.isEmpty ? fallbackName : newValue
            }
        }
        .onChange(of: index) {
            if policy.name.isEmpty, focusedField != .name {
                nameText = fallbackName
            }
        }
        .onChange(of: policy.idleMinutes) { _, newValue in
            if focusedField != .idle { idleMinutesText = String(newValue) }
        }
        .onChange(of: policy.startMinutes) {
            if focusedField != .start { startTimeText = LockScreenPolicy.clockText(policy.startMinutes) }
        }
        .onChange(of: policy.endMinutes) {
            if focusedField != .end { endTimeText = LockScreenPolicy.clockText(policy.endMinutes) }
        }
        .onChange(of: startTimeText) { applyStartTimeIfValid() }
        .onChange(of: endTimeText) { applyEndTimeIfValid() }
        .onChange(of: nameText) {
            if nameText.count > LockScreenPolicy.maximumNameLength {
                nameText = String(nameText.prefix(LockScreenPolicy.maximumNameLength))
            }
            scheduleNameSave()
        }
        .onChange(of: idleMinutesText) { scheduleIdleMinutesSave() }
        .onChange(of: focusedField) { _, field in
            if let previousFocusedField, previousFocusedField != field {
                finishEditing(previousFocusedField)
            }
            previousFocusedField = field
        }
        .onDisappear {
            nameSaveTask?.cancel()
            idleSaveTask?.cancel()
            conflictFlashTask?.cancel()
            if let focusedField { finishEditing(focusedField) }
        }
    }

    private var dayScopeBinding: Binding<LockScreenDayScope> {
        Binding(
            get: { policy.dayScope },
            set: { value in
                update {
                    $0.dayScope = value
                    if value == .custom && $0.customWeekdays.isEmpty {
                        $0.customWeekdays = Set(2...6)
                    }
                }
            }
        )
    }

    private var powerConditionBinding: Binding<LockScreenPowerCondition> {
        Binding(
            get: { policy.powerCondition },
            set: { value in update { $0.powerCondition = value } }
        )
    }

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { policy.isEnabled },
            set: { value in update { $0.isEnabled = value } }
        )
    }

    private var conflictingPolicies: [LockScreenPolicy] {
        LockScreenPolicyResolver.conflictingPolicies(
            for: policy,
            in: settings.lockScreenPolicies
        )
    }

    private var conflictText: String {
        let names = conflictingPolicies.map(displayName(for:)).joined(separator: "、")
        return "与\(names)重叠，重叠时采用较短的闲置时长"
    }

    private func displayName(for conflictingPolicy: LockScreenPolicy) -> String {
        if !conflictingPolicy.name.isEmpty {
            return "“\(conflictingPolicy.name)”"
        }
        let position = settings.lockScreenPolicies.firstIndex { $0.id == conflictingPolicy.id } ?? 0
        return "“时间段 \(position + 1)”"
    }

    private func update(_ mutate: (inout LockScreenPolicy) -> Void) {
        guard let currentPolicy = settings.lockScreenPolicies.first(where: { $0.id == policy.id }) else {
            return
        }
        var updatedPolicy = currentPolicy
        mutate(&updatedPolicy)
        updatedPolicy.normalize()
        let newConflictIDs = LockScreenPolicyResolver.newlyConflictingPolicyIDs(
            for: updatedPolicy,
            replacing: currentPolicy,
            in: settings.lockScreenPolicies
        )
        if !newConflictIDs.isEmpty {
            flashConflict()
        }
        settings.updateLockScreenPolicy(id: policy.id, mutate)
    }

    private func flashConflict() {
        conflictFlashTask?.cancel()
        conflictFlashTask = Task { @MainActor in
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    conflictFlashVisible = true
                }
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
                withAnimation(.easeInOut(duration: 0.16)) {
                    conflictFlashVisible = false
                }
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
            }
            conflictFlashTask = nil
        }
    }

    private var parsedIdleMinutes: Int? {
        guard let minutes = Int(idleMinutesText), (1...1_440).contains(minutes) else { return nil }
        return minutes
    }

    private var idleStatusText: String {
        guard policy.isEnabled else { return "已暂停，设置仍会保留" }
        guard let minutes = parsedIdleMinutes else { return "请输入 1 至 1440 分钟，当前内容未保存" }
        guard minutes == policy.idleMinutes else { return "正在自动保存 \(minutes) 分钟" }
        if isActive {
            return "已保存并应用到系统：\(minutes) 分钟"
        }
        if settings.lockScreenPoliciesEnabled {
            return "已保存：\(minutes) 分钟，等待生效时段"
        }
        return "已保存：\(minutes) 分钟，开启自动锁屏后生效"
    }

    private var idleStatusIcon: String {
        guard policy.isEnabled else { return "pause.circle.fill" }
        guard let minutes = parsedIdleMinutes else { return "exclamationmark.circle.fill" }
        return minutes == policy.idleMinutes ? "checkmark.circle.fill" : "clock"
    }

    private var idleStatusColor: Color {
        guard policy.isEnabled else { return .secondary }
        guard let minutes = parsedIdleMinutes else { return .red }
        return minutes == policy.idleMinutes ? .green : .secondary
    }

    private func scheduleIdleMinutesSave() {
        idleSaveTask?.cancel()
        guard parsedIdleMinutes != nil else { return }
        idleSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveIdleMinutes()
        }
    }

    private func saveIdleMinutes() {
        idleSaveTask?.cancel()
        guard let minutes = parsedIdleMinutes else { return }
        update { $0.idleMinutes = minutes }
    }

    private var fallbackName: String {
        "时间段 \(index + 1)"
    }

    private func saveName() {
        nameSaveTask?.cancel()
        let normalized = LockScreenPolicy.normalizedName(nameText)
        update { $0.name = normalized }
        if !normalized.isEmpty {
            nameText = normalized
        } else if focusedField != .name {
            nameText = fallbackName
        }
    }

    private func scheduleNameSave() {
        nameSaveTask?.cancel()
        guard focusedField == .name else { return }
        nameSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            saveName()
        }
    }

    @ViewBuilder
    private func timeField(
        text: Binding<String>,
        field: EditorField
    ) -> some View {
        TextField("HH:mm", text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .focused($focusedField, equals: field)
            .onSubmit {
                finishEditing(field)
                focusedField = nil
            }
    }

    private func applyStartTimeIfValid() {
        guard let minutes = LockScreenPolicy.minutes(from: startTimeText) else { return }
        update { $0.setStartMinutes(minutes) }
    }

    private func applyEndTimeIfValid() {
        guard let minutes = LockScreenPolicy.minutes(
            from: endTimeText,
            maximumHour: LockScreenPolicy.maximumExtendedHour
        ) else { return }
        update { $0.setEndMinutes(minutes) }
    }

    private func finishEditing(_ field: EditorField) {
        switch field {
        case .name:
            saveName()
        case .start:
            applyStartTimeIfValid()
            restore(field)
        case .end:
            applyEndTimeIfValid()
            restore(field)
        case .idle:
            saveIdleMinutes()
        }
    }

    private func restore(_ field: EditorField) {
        guard let current = settings.lockScreenPolicies.first(where: { $0.id == policy.id }) else { return }
        switch field {
        case .name:
            nameText = current.name.isEmpty ? fallbackName : current.name
        case .start:
            startTimeText = LockScreenPolicy.clockText(current.startMinutes)
        case .end:
            endTimeText = LockScreenPolicy.clockText(current.endMinutes)
        case .idle:
            idleMinutesText = String(current.idleMinutes)
        }
    }

    private func syncEditorText() {
        nameText = policy.name.isEmpty ? fallbackName : policy.name
        idleMinutesText = String(policy.idleMinutes)
        startTimeText = LockScreenPolicy.clockText(policy.startMinutes)
        endTimeText = LockScreenPolicy.clockText(policy.endMinutes)
    }

}

private struct CustomWeekdayPicker: View {
    let selected: Set<Int>
    let toggle: (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            weekdayButton(1, title: "日")
            weekdayButton(2, title: "一")
            weekdayButton(3, title: "二")
            weekdayButton(4, title: "三")
            weekdayButton(5, title: "四")
            weekdayButton(6, title: "五")
            weekdayButton(7, title: "六")
        }
    }

    private func weekdayButton(_ weekday: Int, title: String) -> some View {
        Button(title) {
            toggle(weekday)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(selected.contains(weekday) ? Color.accentColor : .secondary)
        .help("星期\(title)")
    }
}

private struct CustomDaysSettingsRow: View {
    let selected: Set<Int>
    let toggle: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsDivider()
            HStack(spacing: 10) {
                Text("自选日期")
                    .font(.body.weight(.medium))
                Spacer(minLength: 12)
                CustomWeekdayPicker(selected: selected, toggle: toggle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }
}
