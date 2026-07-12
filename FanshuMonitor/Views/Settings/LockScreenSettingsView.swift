import SwiftUI

struct LockScreenSettingsView: View {
    @ObservedObject var settings: MonitorSettings
    @ObservedObject var controller: LockScreenPolicyController

    var body: some View {
        SettingsPage {
            SettingsGroup("自动锁屏") {
                SettingsRow(
                    title: "启用时间策略",
                    subtitle: "按时段启动系统屏保，到时自动锁屏"
                ) {
                    Toggle("", isOn: $settings.lockScreenPoliciesEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsDivider()

                HStack(spacing: 10) {
                    Image(systemName: settings.lockScreenPoliciesEnabled ? "clock.badge.checkmark" : "clock")
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

            SettingsGroup("时间策略") {
                if settings.lockScreenPolicies.isEmpty {
                    ContentUnavailableView {
                        Label("还没有时间策略", systemImage: "clock.badge.plus")
                    } description: {
                        Text("添加策略后才会修改系统锁屏时间")
                    } actions: {
                        Button("添加策略") {
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
                            Label("添加策略", systemImage: "plus")
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
    }
}

private struct LockScreenPolicyEditor: View {
    let policy: LockScreenPolicy
    @ObservedObject var settings: MonitorSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()

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
                DatePicker("开始", selection: dateBinding(for: \.startMinutes), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                Text("至")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("结束", selection: dateBinding(for: \.endMinutes), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()

                Spacer(minLength: 8)

                Picker("闲置", selection: idleMinutesBinding) {
                    ForEach([1, 2, 5, 10, 15, 30, 60, 120], id: \.self) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
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
        .opacity(policy.isEnabled ? 1 : 0.52)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { policy.isEnabled },
            set: { value in update { $0.isEnabled = value } }
        )
    }

    private var dayScopeBinding: Binding<LockScreenDayScope> {
        Binding(
            get: { policy.dayScope },
            set: { value in update { $0.dayScope = value } }
        )
    }

    private var idleMinutesBinding: Binding<Int> {
        Binding(
            get: { policy.idleMinutes },
            set: { value in update { $0.idleMinutes = value } }
        )
    }

    private func dateBinding(for keyPath: WritableKeyPath<LockScreenPolicy, Int>) -> Binding<Date> {
        Binding(
            get: {
                Date(timeIntervalSinceReferenceDate: TimeInterval(policy[keyPath: keyPath] * 60))
            },
            set: { date in
                let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
                update { $0[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0) }
            }
        )
    }

    private func update(_ mutate: (inout LockScreenPolicy) -> Void) {
        var updated = policy
        mutate(&updated)
        settings.updateLockScreenPolicy(updated)
    }
}
