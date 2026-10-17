# 代码审查报告（问题清单）

日期：2026-10-17

基线：`87bd81a`。本报告为**只读审查**，未修改任何源码。

## 审查范围与方式

覆盖 `FanshuMonitor`（核心、`Samplers`、`Views/Settings`、`Views/Panel`）、`FanshuMonitorDisplay`、`FanshuMonitorTests`，重点检查：

- 采样调度（`SamplingCoordinator`、`MonitorRefreshSchedule`、`MonitorModuleSamplerWorker`、各 Sampler）
- 显示器控制（`DisplayControlController`、`DisplayControlService`、`DisplayDDCBridge`、`BuiltInDisplayBlackoutService`、电源/拓扑桥）
- 锁屏策略（`LockScreenPolicy`、`LockScreenPolicyController`、系统观察与桥）
- 鼠标/HID（`MouseControlController`、`MouseButtonEventTap`、`MouseActionExecutor`、Logitech HID++ 监听与服务）
- 设置与持久化（`MonitorSettings`、`MonitorSettingsPersistence`、`LockScreenSettingsView`、`MouseSettingsView`、`GeneralSettingsView`）
- 更新检查（`UpdateChecker`）与 Codex 配额（`CodexQuotaSampler`）

方式：直接通读核心文件，并对子系统做并行审查后交叉复核关键行。每条尽量标注可定位的 `文件:行号`。结论基于源码，未做全部硬件组合的实机验收。

仓库中 `FanshuMonitor/UpdateChecker.swift`、`FanshuMonitorTests/UpdateCheckerTests.swift` 的未提交改动是审查前既有内容，本次未触碰。

## 严重（可能导致崩溃 / 内存错误）

### H1. `CGDisplayConfigRef` 被重复释放（use-after-free）

- 位置：`FanshuMonitorDisplay/BuiltInDisplayBlackoutService.swift:338-340`（`configureMirroring` 内）
- 问题：先 `CGCompleteDisplayConfiguration(config, .permanently)`，紧接着又 `CGCancelDisplayConfiguration(config)`。`CGCompleteDisplayConfiguration` 会消费/失效该 config，再 cancel 属于对已释放句柄二次操作。
- 对照：同文件 `configureDisplay`（约 `269-277`）与 `DisplayControlService.applyDisplayMode`（约 `218-221`）都**只** complete、不 cancel，并注释说明 config 已被消费，说明此处是手误。
- 影响：镜像/内置屏压黑流程走到这里可能崩溃或内存损坏，属随机、难复现的一类问题。
- 建议：删除该 `CGCancelDisplayConfiguration`；如需失败回滚，应在 complete 之前 cancel。

## 中等（功能缺陷 / 潜在内存问题）

### M1. 只是打开锁屏设置页再退出，就会静默改写系统屏保/密码设置

- 位置：`FanshuMonitor/Views/Settings/LockScreenSettingsView.swift:178-181`、`:320-335`、`:347-360`
- 问题：`.onDisappear` 无条件调用 `applySystemSettingsIfValid()`，而它只校验“文本能解析成合法整数”，**不判断用户是否真的改过**。字段默认值为硬编码 `systemIdleMinutesText="10"`、`systemRequirePassword=true`、`systemPasswordDelayText="0"`（`:6-8`）；`syncSystemSettings` 只在系统值存在时才覆盖默认值（`:323-331`）。
- 触发：若系统 `com.apple.screensaver` 缺少 `idleTime`（`ScreenSaverLockBaseline.idleMinutes` 为 nil），或缺少 `askForPassword`/`askForPasswordDelay`，默认值会保留；用户“进去看一眼再出来”就会把系统写成「10 分钟屏保 + 要求密码 + 0 秒延迟」。即使系统值存在，`idleMinutes` 走 `rounded(.up)` 取整，也可能把非整分钟的原值改掉。
- 建议：`onDisappear` 只做取消/保存，不 apply；apply 仅由用户编辑（dirty 标记）触发。

### M2. 屏保关闭（idle=0）时，密码相关修改被静默丢弃

- 位置：`LockScreenSettingsView.swift:347-352`
- 问题：guard 要求 `Int(systemIdleMinutesText)` 落在 `1...1440`。屏保关闭时 `idleTime=0`，字段显示 `"0"`，条件为 false → 直接 `return`，对“要求密码 / 密码延迟”的改动不写回，且无任何提示。
- 建议：将 idle 校验与密码设置解耦；`idle==0` 视为“关闭屏保”也是合法状态。

### M3. 电源事件桥用未持有引用作 refcon，存在悬垂指针风险

- 位置：`FanshuMonitorDisplay/DisplayPowerEventBridge.swift:41-42`、`:55`、`:94-99`、`:101-103`
- 问题：`refcon` 使用 `Unmanaged.passUnretained(self)`，而 `stop()` 仅 `IONotificationPortSetDispatchQueue(port, nil)` 后销毁端口——**已排队的回调块不保证被丢弃**。对象在 `deinit`/已释放时，队列上的回调仍会 `takeUnretainedValue()` → use-after-free。`rootPort` 也跨线程无同步读取（`:83`）。
- 同类潜伏：`DisplayHardwareTopologyBridge.swift`（约 `173`、`193-203`、`290-299`）使用同样的未持有引用 + 异步投递模式。
- 缓解：`send()` 的异步部分捕获的是 `handler` 而非 `self`（`:96`），风险集中在同步 `receive`。
- 建议：改用带有效性 token 的方式在回调内校验，或让 `stop()` 与投递队列串行化后再释放。

### M4. Codex 配额缓存写入忽略 `fetchedAt`，导致“更新时间”永久偏旧

- 位置：`FanshuMonitor/Samplers/CodexQuotaSampler.swift:649-661`（`CodexQuotaCache.save`），消费点 `:338`，写入点 `:524`
- 问题：`save` 在 `planType/periods/resetCredits` 都相同时直接 `return`，**不比较 `fetchedAt`**。即使后续成功拉取、内容未变，缓存里的 `fetchedAt` 也停在第一次，界面“更新于”一直显示旧值。
- 建议：比较时纳入 `fetchedAt`，或内容不变时单独刷新 `fetchedAt`。

### M5. “设定”按钮用的是滑杆值，不是输入框里刚键入的值

- 位置：`FanshuMonitor/Views/Settings/MouseSettingsView.swift:108-110`，对比 `:137-140`、`:163-174`
- 问题：用户在 DPI 输入框里输入新值但**未回车**时，点“设定”应用的是旧的 `dpi`（滑杆绑定值），输入被忽略。预设按钮（`:118-131`）也只改 `dpi` 不 apply，用户很可能按流程点“设定”而拿到错误结果。
- 建议：“设定”改为先 `commitDPIText()` 再 apply，或直接以 `dpiText` 为准。

### M6. DDC 通道超时两次后永久失联

- 位置：`FanshuMonitorDisplay/DisplayDDCBridge.swift:394-421`
- 问题：`lease()` 在 `channel.timeoutCount > maximumRecoveries`（默认 1）且过了 quarantine 之后**依然返回 nil**，且无周期性自愈清零 `timeoutCount`；只有外部显式 `reset(displayID:)` 才能恢复。上层若未在恰当时机 reset，该显示器的 DDC 亮度/对比度会持续失败。
- 建议：加入更长的退避重试窗口，或在成功一次后清零 `timeoutCount`。

## 低（健壮性 / 体验 / 规范）

| 编号 | 位置 | 问题 |
| --- | --- | --- |
| L1 | `FanshuMonitorDisplay/BrightnessKeyEventTap.swift:22-26`、`:62-71` | `deinit` 里 `MainActor.assumeIsolated { stop() }`，非主线程释放会 trap；`stop()` 只 disable 未 `CFMachPortInvalidate`（对比 `MouseButtonEventTap` 有做），可能残留资源 |
| L2 | `FanshuMonitorDisplay/DisplayControlController.swift:391-403`、`:1014-1036` | 睡眠期间“取消的写入”与“标记不支持”之间存在跨队列时序窗口，可能把被取消的写入误判为 `markControlUnsupported` |
| L3 | `DisplayControlController.swift:643-700` | 媒体键路径在“displays 为空 / 目标不在列表”分支会无节流地 `refreshNow()` |
| L4 | `FanshuMonitorDisplay/DisplayControlWorker.swift:164-174` | 合并后的 discovery 可能跑着过期的 `activeControls` |
| L5 | `FanshuMonitor/UpdateChecker.swift:247-258`、`:238-245` | `resolveDownloadURL` 遇到第一个 `.dmg/.zip` 判定非官方即 `return nil`，不继续找后续候选；`clearReleaseCache` 连 `lastAutomaticCheckKey` 一并清掉，会与 `checkAutomaticallyIfNeeded` 节流互相影响，建议确认是否有意为之 |
| L6 | `FanshuMonitor/Samplers/CodexQuotaSampler.swift:473` | `load()` 硬编码 `Date()`，未走可注入时钟（`parseUsage` 本身支持 `now:`），与其它采样器可测试风格不一致 |
| L7 | `FanshuMonitor/Views/Settings/GeneralSettingsView.swift:7-8` | `@State` 初值里执行 `AXIsProcessTrusted()` / `CGPreflightListenEventAccess()`；view struct 频繁重建会反复查询 TCC，与项目“授权状态只在启动/激活/用户操作时检查”的约定精神不符，建议移到 `.onAppear`/`.task` |
| L8 | `FanshuMonitor/Views/Settings/MouseSettingsView.swift:177-230` | 自绘 `MouseDPITrackSlider` 只有 `DragGesture`，缺 `accessibilityValue`/`accessibilityAdjustableAction` 与键盘路径，VoiceOver/键盘用户无法调 DPI |
| L9 | `FanshuMonitor/MonitorModels.swift`（`MonitorModule.placeholder(kind: .codex)`） | 占位模块仍用 `current/average/peak` 旧指标名，与 Codex 实际指标（`plan`/`five-hour`/…）不一致，空缓存时展示可能回退不全 |
| L10 | `FanshuMonitor/Samplers/SMC.swift`（`fourCharCodeToString`） | `UnicodeScalar(...)!` 对外部数据强解包；字节落在 `0xD8-0xDF` 区间时返回 nil 会崩，概率极低但属外部数据强解包 |

## 尚不确定 / 建议复核

- `LockScreenSettingsView.swift:320-335` 与 `:337-344`：`syncSystemSettings` 同步改文本后，用 `DispatchQueue.main.async` 复位 `isSyncingSystemSettings`，而 `.onChange` 下一轮渲染才派发，二者存在竞态，可能导致“加载系统值”本身触发一次误 apply。建议改成显式“正在同步”作用域或直接对比旧/新值。
- 审查中还出现过若干 `DisplayControlController`/`DisplaySoftwareDimmingService` 的边界路径疑点，未逐条复现，暂不列入正文。

## 小结与优先级

整体结构清晰：采样分层、按需加载、`@MainActor` 边界处理较为讲究。建议优先级：

1. **H1**（`CGDisplayConfigRef` 重复释放）——潜在崩溃，尽快修。
2. **M1 / M2**——会静默改动系统锁屏/密码设置，用户可感知且关乎安全，应优先处理。
3. **M3 / M4 / M5 / M6**——功能与内存健壮性问题，按迭代排期修复。
4. **L1-L10**——健壮性、体验与规范类，可随版本逐步清理。

后续如需，可就 H1、M1、M2 单独出修复补丁与回归用例。
