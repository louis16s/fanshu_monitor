import SwiftUI

struct LockScreenSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @ObservedObject var controller: LockScreenPolicyController
    @State private var systemIdleMinutes = 10
    @State private var systemRequirePassword = true
    @State private var systemPasswordDelaySeconds = 0

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
                    Image(systemName: settings.lockScreenPoliciesEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(settings.lockScreenPoliciesEnabled ? Color.accentColor : .secondary)
                    Text(controller.statusText)
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
                        TextField("分钟", value: $systemIdleMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 58)
                            .multilineTextAlignment(.trailing)
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
                }

                if systemRequirePassword {
                    SettingsDivider()

                    SettingsRow(title: "密码延迟", subtitle: "屏保启动后多久要求密码") {
                        HStack(spacing: 6) {
                            TextField("秒", value: $systemPasswordDelaySeconds, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 58)
                                .multilineTextAlignment(.trailing)
                            Text("秒")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsDivider()

                HStack {
                    Text(settings.lockScreenPoliciesEnabled ? "时间策略启用时会覆盖系统设置" : "关闭时间策略后可直接修改系统设置")
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

                    Button("保存到系统") {
                        controller.applySystemSettings(
                            idleMinutes: systemIdleMinutes,
                            requirePassword: systemRequirePassword,
                            passwordDelaySeconds: systemPasswordDelaySeconds
                        )
                    }
                    .controlSize(.small)
                    .disabled(settings.lockScreenPoliciesEnabled)
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
        .onChange(of: controller.systemSettings) { newValue in
            syncSystemSettings(newValue)
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
        if let minutes = systemSettings.idleMinutes {
            systemIdleMinutes = minutes
        }
        if let requiresPassword = systemSettings.askForPassword {
            systemRequirePassword = requiresPassword
        }
        if let delay = systemSettings.askForPasswordDelay {
            systemPasswordDelaySeconds = delay
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("生效日期")
                    .font(.body.weight(.medium))

                Picker("日期", selection: dayScopeBinding) {
                    ForEach(LockScreenDayScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    settings.removeLockScreenPolicy(id: policy.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除此策略")
            }

            HStack(spacing: 8) {
                TextField("HH:mm", text: $startTimeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .focused($focusedField, equals: .start)
                    .onSubmit { commitTime(startTimeText, for: \.startMinutes) }
                Text("至")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("HH:mm", text: $endTimeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .focused($focusedField, equals: .end)
                    .onSubmit { commitTime(endTimeText, for: \.endMinutes) }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    TextField("闲置", text: $idleMinutesText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($focusedField, equals: .idle)
                        .onSubmit(commitIdleMinutes)
                    Text("分钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    syncEditorText()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("恢复这条时间的已保存值")
            }

            if policy.dayScope == .custom {
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { weekday in
                        Button(weekdayTitle(weekday)) {
                            update { $0.toggleCustomWeekday(weekday) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(policy.customWeekdays.contains(weekday) ? Color.accentColor : .secondary)
                        .help("\(weekdayLongTitle(weekday))")
                    }
                }
            }

            if !policy.hasValidTimeRange {
                Text("开始和结束时间不能相同")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if policy.crossesMidnight {
                Text("跨日时段按开始当天归类")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onAppear { syncEditorText() }
        .onChange(of: policy.idleMinutes) { newValue in
            idleMinutesText = String(newValue)
        }
        .onChange(of: policy.startMinutes) { _ in startTimeText = LockScreenPolicy.clockText(policy.startMinutes) }
        .onChange(of: policy.endMinutes) { _ in endTimeText = LockScreenPolicy.clockText(policy.endMinutes) }
        .onChange(of: focusedField) { field in
            if field != .start { commitTime(startTimeText, for: \.startMinutes) }
            if field != .end { commitTime(endTimeText, for: \.endMinutes) }
            if field != .idle { commitIdleMinutes() }
        }
        .onDisappear {
            commitTime(startTimeText, for: \.startMinutes)
            commitTime(endTimeText, for: \.endMinutes)
            commitIdleMinutes()
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
        var updated = policy
        mutate(&updated)
        settings.updateLockScreenPolicy(updated)
    }

    private func commitIdleMinutes() {
        guard let minutes = Int(idleMinutesText) else {
            idleMinutesText = String(policy.idleMinutes)
            return
        }
        let clampedMinutes = min(1_440, max(1, minutes))
        guard clampedMinutes != policy.idleMinutes else { return }
        update { $0.idleMinutes = clampedMinutes }
    }

    private func commitTime(_ text: String, for keyPath: WritableKeyPath<LockScreenPolicy, Int>) {
        guard let minutes = LockScreenPolicy.minutes(from: text) else {
            syncEditorText()
            return
        }
        guard minutes != policy[keyPath: keyPath] else { return }
        update { $0[keyPath: keyPath] = minutes }
    }

    private func syncEditorText() {
        idleMinutesText = String(policy.idleMinutes)
        startTimeText = LockScreenPolicy.clockText(policy.startMinutes)
        endTimeText = LockScreenPolicy.clockText(policy.endMinutes)
    }

    private func weekdayTitle(_ weekday: Int) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
    }

    private func weekdayLongTitle(_ weekday: Int) -> String {
        "星期\(weekdayTitle(weekday))"
    }
}
