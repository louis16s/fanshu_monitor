import SwiftUI

struct LockScreenSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @ObservedObject var controller: LockScreenPolicyController
    @State private var systemIdleMinutesText = "10"
    @State private var systemRequirePassword = true
    @State private var systemPasswordDelayText = "0"
    @State private var systemApplyTask: Task<Void, Never>?
    @State private var isSyncingSystemSettings = false

    var body: some View {
        SettingsPage {
            SettingsGroup("自动锁屏") {
                SettingsRow(
                    title: "自动锁屏",
                    subtitle: "打开后，下方所有时间规则都会生效"
                ) {
                    Toggle("", isOn: policyMasterBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                HStack(spacing: 10) {
                    Image(systemName: settings.lockScreenPoliciesEnabled ? "clock.badge.checkmark.fill" : "clock")
                        .foregroundStyle(settings.lockScreenPoliciesEnabled ? Color.accentColor : .secondary)
                    Text(settings.lockScreenPoliciesEnabled ? controller.statusText : "时间策略未启用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if settings.lockScreenPoliciesEnabled {
                        Button {
                            controller.restoreOriginalSettings()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("恢复原来的系统锁屏设置")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }

            SettingsGroup("安全") {
                SettingsRow(
                    title: "立即需要密码",
                    subtitle: "策略生效时，屏保启动后立即要求密码"
                ) {
                    Toggle("", isOn: $settings.lockScreenRequirePassword)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            SettingsGroup("系统锁屏设置") {
                SettingsRow(title: "屏保启动时间", subtitle: "当前：\(systemIdleDescription)") {
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

                SettingsRow(title: "要求密码", subtitle: "当前：\(systemPasswordDescription)") {
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

            SettingsGroup("锁屏时间") {
                if settings.lockScreenPolicies.isEmpty {
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
                } else {
                    ForEach(Array(settings.lockScreenPolicies.enumerated()), id: \.element.id) { index, policy in
                        LockScreenPolicyEditor(policy: policy, settings: settings)
                        if index < settings.lockScreenPolicies.count - 1 {
                            SettingsDivider()
                        }
                    }

                    if settings.lockScreenPolicies.count < MonitorSettings.maximumLockScreenPolicies {
                        SettingsDivider()
                        Button {
                            settings.addLockScreenPolicy()
                        } label: {
                            Label("添加锁屏时间", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 10)
                    }
                }
            }

            Text("时段以本机时间为准，未覆盖的时间沿用系统的原设置")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
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
        .onDisappear {
            systemApplyTask?.cancel()
            applySystemSettingsIfValid()
        }
    }

    private var systemIdleDescription: String {
        guard let minutes = controller.systemSettings.idleMinutes else { return "系统默认" }
        return "\(minutes) 分钟"
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
        case start
        case end
        case idle
    }

    let policy: LockScreenPolicy
    @ObservedObject var settings: MonitorSettings
    @State private var idleMinutesText = ""
    @State private var startTimeText = ""
    @State private var endTimeText = ""
    @FocusState private var focusedField: EditorField?
    @State private var previousFocusedField: EditorField?

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: "生效日期") {
                HStack(spacing: 8) {
                    Picker("日期", selection: dayScopeBinding) {
                        ForEach(LockScreenDayScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Button(role: .destructive) {
                        settings.removeLockScreenPolicy(id: policy.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除这条锁屏时间")
                }
            }

            SettingsDivider()

            SettingsRow(title: "开始时间", subtitle: "24 小时制") {
                timeField(text: $startTimeText, field: .start)
            }

            SettingsDivider()

            SettingsRow(title: "结束时间", subtitle: "可输入 24:00 表示当天结束") {
                timeField(text: $endTimeText, field: .end)
            }

            SettingsDivider()

            SettingsRow(title: "闲置后锁屏", subtitle: "1 至 1440 分钟，输入后自动生效") {
                HStack(spacing: 6) {
                    TextField("分钟", text: $idleMinutesText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($focusedField, equals: .idle)
                        .onSubmit {
                            normalize(.idle)
                            focusedField = nil
                        }
                    Text("分钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        restore(.idle)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("恢复已保存的闲置时间")
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
            } else if policy.crossesMidnight {
                SettingsDivider()
                Text("跨日时段按开始当天归类")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { syncEditorText() }
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
        .onChange(of: idleMinutesText) { applyIdleMinutesIfValid() }
        .onChange(of: focusedField) { _, field in
            if let previousFocusedField, previousFocusedField != field {
                normalize(previousFocusedField)
            }
            previousFocusedField = field
        }
        .onDisappear {
            if let focusedField { normalize(focusedField) }
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

    private func update(_ mutate: (inout LockScreenPolicy) -> Void) {
        settings.updateLockScreenPolicy(id: policy.id, mutate)
    }

    private func applyIdleMinutesIfValid() {
        guard let minutes = Int(idleMinutesText), (1...1_440).contains(minutes) else { return }
        update { $0.idleMinutes = minutes }
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
                normalize(field)
                focusedField = nil
            }
    }

    private func applyStartTimeIfValid() {
        guard let minutes = LockScreenPolicy.minutes(from: startTimeText) else { return }
        update { $0.startMinutes = minutes }
    }

    private func applyEndTimeIfValid() {
        guard let minutes = LockScreenPolicy.minutes(from: endTimeText, allowsEndOfDay: true) else { return }
        update { $0.endMinutes = minutes }
    }

    private func normalize(_ field: EditorField) {
        switch field {
        case .start:
            applyStartTimeIfValid()
        case .end:
            applyEndTimeIfValid()
        case .idle:
            applyIdleMinutesIfValid()
        }
        restore(field)
    }

    private func restore(_ field: EditorField) {
        guard let current = settings.lockScreenPolicies.first(where: { $0.id == policy.id }) else { return }
        switch field {
        case .start:
            startTimeText = LockScreenPolicy.clockText(current.startMinutes)
        case .end:
            endTimeText = LockScreenPolicy.clockText(current.endMinutes)
        case .idle:
            idleMinutesText = String(current.idleMinutes)
        }
    }

    private func syncEditorText() {
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
