# 代码审查报告（第二轮复审）

日期：2026-10-17

对应审查：`CODE_REVIEW_2026-10-17.md`
复审基线：`87bd81a` → `2a83937`（`Fix verified code review findings`）
修复记录：`CODE_REVIEW_REMEDIATION_2026-10-17.md`

本报告为**只读复审**，未修改任何源码。

## 复审范围与方式

逐条核对修复提交 `2a83937` 的 diff，并对修复引入的新代码路径做行级复核。覆盖显示器控制、锁屏设置、电源/拓扑桥、Codex 配额缓存、DPI 控件、SMC 解析。

工作区中 `FanshuMonitor/UpdateChecker.swift`、`FanshuMonitorTests/UpdateCheckerTests.swift` 仍为未提交的修改（缓存过期逻辑 WIP），不是本次修复提交的内容，单独在末节讨论。

## 一、上一轮问题的修复确认

| 编号 | 状态 | 复核结论 |
| --- | --- | --- |
| H1 | 已修 | `BuiltInDisplayBlackoutService.swift:338-343` 已删除 `CGCompleteDisplayConfiguration` 之后的 `CGCancelDisplayConfiguration`，与 `configureDisplay`（`:265` 在 complete 之前 cancel）语义一致。全仓库再无「complete 之后再 cancel」的写法（`DisplayControlService.swift:219/223` 也是在 complete 之前 cancel）。判断正确。 |
| M1 | 已修 | `LockScreenSettingsView` 改为三个显式 dirty 标志（`:10-12`）；文本框/开关改走自定义 Binding（`:370-390`），只有用户输入才置位并触发防抖保存；`syncSystemSettings`（`:320-335`）用原始 `@State` 赋值并清零标志。单纯进出设置页不再写系统值。 |
| M2 | 已修 | `applySystemSettings` 与 `ScreenSaverLockPreferences.applyChanges`（`LockScreenSystemBridge.swift:163-185`）改为三参数可选，只写用户改动过的字段；idle 下限放开为 `0`（`LockScreenPolicyController.swift:255`），屏保关闭状态也能独立改密码项。有对应回归用例。 |
| M3 | 大部分修 | 拓扑桥改 `passRetained` + 延迟 release（`DisplayHardwareTopologyBridge.swift:165-166,206-215`），持有者在 `stop`/`deinit` 都会 `bridge.stop()`，不会泄漏；电源桥加了队列排空（`DisplayPowerEventBridge.swift:68-71`）。遗留竞态见 N1。 |
| M4 | 已修 | `CodexQuotaCache.save` 的相等判断纳入 `fetchedAt`（分钟精度），有回归用例。 |
| M5 | 已修 | 「设定」按钮改为 `commitDPIText()`（`MouseSettingsView.swift:108-110`），走统一解析/限幅/apply 流程。 |
| L7 | 已修 | `GeneralSettingsView` 初值改为 `false`，改在 `.onAppear` 与 `didBecomeActive` 查询（`:7-8,114-121,136-139`）。 |
| L8 | 已修 | 自绘 DPI 滑杆补了 `accessibilityLabel/Value/AdjustableAction`（`MouseSettingsView.swift:227-234`）。 |
| L10 | 已修 | SMC 四字符码改用字节数组 + 编码回退（`SMC.swift` `fourCharCodeToString`），去掉强解包。 |

结论：H1、M1、M2、M4、M5 及 L7/L8/L10 修复正确，且都补了针对性测试或与既有约定一致。

## 二、本次新发现

### N1（低偏中）电源事件桥的竞态只是收窄，未消除；且新增一个主线程同步点

- `FanshuMonitorDisplay/DisplayPowerEventBridge.swift:44` 仍是 `Unmanaged.passUnretained(self)`。
- `stop()`（`:60-80`）顺序是：先 `IONotificationPortSetDispatchQueue(port, nil)`，再 `deliveryQueue.sync {}` 排空。已知 `IONotificationPortSetDispatchQueue` 与「已经在途的投递」之间不是强同步：若内核在 `setDispatchQueue(nil)` 返回之后才把回调块排入队列，它可能排在排空之后执行，仍在 `deinit` 之后调用 `takeUnretainedValue()`（UAF 窗口变小但没消失）。
- 建议：像拓扑桥那样改成 `passRetained` + 延迟 release，或在 `IOServiceClose` 之后再补一次排空。
- 附带：`stop()` 现在会从主线程 `deliveryQueue.sync {}`。当前 `earlyHandler`（`DisplayControlController.swift:408-415`）只做非阻塞操作（`configurationLock`/`lifecycleLock`/`stateLock` + 异步派发），不等待主线程，**暂不会死锁**；但这是新引入的主线程↔投递队列同步点，后续若往 `earlyHandler` 里加入等待主线程的逻辑就会死锁，需要作为约束保留。

### N2（低）拓扑桥没有 `deinit`，`passRetained` 的自持依赖调用方一定调用 `stop()`

- `DisplayHardwareTopologyBridge` 自身无 `deinit`（`DisplayHardwareTopologyBridge.swift:126-153`）。`passRetained(self)` 的 +1 只在 `stop()` 里释放。
- 目前唯一持有者 `DisplayHardwareTopologyMonitor` 在 `stop()`（`:57-62`）与 `deinit`（`:117-120`）都会调用 `bridge.stop()`，所以不会泄漏。但一旦将来有别的调用点直接丢弃 bridge，就会 +1 自持泄漏并且通知端口常驻。建议给 bridge 加一个 `deinit { stop() }` 兜底（`retainedCallbackRefcon` 置空后重复调用是安全的）。

### N3（低）`ScreenSaverLockPreferences.apply` 成为死代码

全仓库已无调用者（只剩 `applyChanges`、`restore`、`prepareDirectLockFallback`）。保留会让人误以为存在「整体覆盖写」的旧行为，建议删除或标注。

### N4（低）屏保时间字段在系统无 `idleTime` 时仍显示默认 “10”

`systemIdleMinutesText` 初值 `"10"`（`LockScreenSettingsView.swift:6`），`syncSystemSettings` 仅在 `idleMinutes != nil` 时覆盖（`:323-325`）。M1 修复后不会再误写系统，但界面会展示一个并非系统真实值的 “10 分钟”，可能误导。建议无系统值时显示空或 “--”。

### N5（低）`makeQuotaTimeFormatter()` 每次调用都新建 `DateFormatter`

`CodexQuotaSampler.swift:381-386`；`save` 的相等判断里最多调用 2 次。`DateFormatter` 构建较贵，虽频率低，建议缓存为静态常量。

## 三、仍保留 / 未修（供决策）

- **M6（DDC 熔断）**：修复记录选择保留。复核认可其资源上限理由——`DisplayDDCBridge.refresh(forceReset:)` 会在服务替换、显示器消失、以及 `shouldResetDDCServiceCache`（拓扑变化/唤醒）时调用 `DDCTransport.reset` 清隔离。**但**残存场景：同一显示器服务身份不变、只有连续 2 次 DDC 超时且期间不发生 forceReset/服务替换时，通道会一直返回 nil。建议至少在长时间后给一次「重置超时计数」的低频自愈。
- **L1**：`BrightnessKeyEventTap.swift:22-26` 的 `deinit` + `MainActor.assumeIsolated` 仍在；`stop()` 仍不 `CFMachPortInvalidate`（对照 `MouseButtonEventTap.swift:29/76/105` 是做的）。未修。
- **L2 / L3 / L4**：控制写入时序窗口、媒体键无节流 `refreshNow()`、合并探测可能用过 `activeControls`，均未修（修复记录解释为证据不足）。
- **L5**：`UpdateChecker.resolveDownloadURL` 命中第一个 `.dmg/.zip` 非官方即 `return nil` 仍在（`:247-258`）；未提交改动里 `clearReleaseCache` 仍会连 `lastAutomaticCheckKey` 一起清。
- **L6**：`CodexQuotaSampler.swift:473` 仍硬编码 `Date()`。
- **L9**：`MonitorModule.placeholder(kind: .codex)` 仍是 `current/average/peak` 旧指标名。

## 四、关于未提交的 UpdateChecker 改动

`git status` 显示 `UpdateChecker.swift` / `UpdateCheckerTests.swift` 仍为修改中状态（`releaseFetchedAtKey` 缓存过期逻辑，+79 行）。行为上有一处需要确认：`discardExpiredReleaseCache()` 会连带清掉 `lastAutomaticCheckKey`，于是当缓存过期且随后一次自动检查失败时，节流键不会写入，会导致更频繁的重试，且缓存里的旧 release 也被清掉（About 面板不再显示旧条目）。若这是有意为之（「过期即视为无效」）则无问题；否则建议把 `lastAutomaticCheckKey` 的清理与 payload 清理解耦。

另外提醒：这批改动与已修复的其它文件是两批内容，提交时注意不要混在一起。

## 五、小结

- 上一轮最严重的 H1 以及会静默改系统设置的 M1/M2 都已正确修复，并有一致性与回归覆盖。
- 需要再花一点力气的有两项：**N1**（电源桥改成 retained refcon 以彻底消除 UAF 窗口）与 **M6** 的残余熔断场景。
- 其余为死代码、默认值展示、formatter 开销等低优先项。

验证说明：本轮为静态复审，未重新执行 `xcodebuild test` 或 Release 构建（避免顺带刷新 `outputs` 改动工作区）。修复提交自身的验证结论以 `CODE_REVIEW_REMEDIATION_2026-10-17.md` 为准；如需，可单独安排一次构建与完整测试复跑。
