# 子代理代码审查与稳定性修复

日期：2026-10-13

基线：`8e66b24`，可通过 Git 历史恢复。应用版本保持 `0.3.3`。

## 审查范围

四个子代理分别审查显示器与亮度、锁屏与鼠标、采样与 Codex、设置与更新。
子代理完成初审及部分交叉复验；后续额度中断后，由主线程接手显示器收尾和最终集成验证。
下面的修复结论基于源码、回归测试与可执行构建，不等同于所有硬件组合的实机验收。

## 已修复

| 模块 | 问题与修复 | 主要文件 |
| --- | --- | --- |
| 设置 | 合法空指标选择保持为空；迁移结果先保存，再标记完成，零编辑重启也能保留 | `MonitorSettings.swift` |
| 锁屏 | 唤醒及解锁后恢复电源监听；闲置到期重新解析时段与供电，原生锁定及回退前重新校验 | `LockScreenSystemObserver.swift`、`LockScreenPolicyController.swift` |
| 鼠标 | HID 重启退避取消路径释放等待者；检查授权撤销、端口有效性、运行循环源及实际启用状态 | `LogitechHIDPPButtonListener.swift`、`MouseButtonEventTap.swift` |
| 显示器睡眠 | 早期睡眠通知关闭调光写入闸门，取消排队写入；拒绝旧发现和写入回调，有效拓扑恢复后才恢复调光 | `DisplayControlController.swift`、`DisplayControlService.swift`、`DisplaySoftwareDimmingService.swift` |
| 显示器恢复 | 重插、睡眠和用户操作使旧恢复事务失效；拓扑及亮度重试前检查取消代次 | `DisplayControlWorker.swift` |
| 显示器亮度 | 关闭软件调光后读取硬件坐标；在线短暂漏报保留调光请求；不可控 DDC 屏幕在亮度键操作时冷却重探测 | `DisplayControlController.swift`、`DisplaySoftwareDimmingService.swift` |
| 采样 | 排队任务在实际执行前检查取消；CPU/GPU 温度失败保留有效旧值，过滤无效温度；GPU 缺失详情显示未知且支持跨 worker 缓存 | `MonitorModuleSamplerWorker.swift`、`CPUSampler.swift`、`GPUSampler.swift`、`MonitorModels.swift` |
| SMC | 连接失败按需退避重建；不支持的 key 与连接失效分开处理 | `SMC.swift` |
| Codex | 失败重试截止时间接入实际调度，无采样需求时取消；大文件初读区分完整行和残行 | `MonitorStore.swift`、`SamplingCoordinator.swift`、`CodexQuotaSampler.swift`、`CodexTaskProgressReader.swift` |
| 更新 | 完整验证后替换缓存，正确删除旧 ETag；坏 304 缓存最多一次无条件重试；下载与缓存恢复校验官方仓库 HTTPS 链接 | `UpdateChecker.swift` |

正常采样间隔、自适应额度刷新规则、额度重置时刻刷新规则保持原配置。
启动只读当前亮度、外接断开恢复内屏至 35%、外接优先策略保持。

## 验证结果

- macOS 27 / Xcode 27：323 项测试、340 次执行通过，零失败
- 静态分析通过
- Release 构建通过，最新 app 与 zip 输出到 `outputs`
- 实际关闭、重开设置窗口三次，侧栏和页面内容均可通过辅助功能树读取
- 回归覆盖睡眠迟到调光、取消恢复事务、键盘与滑杆混用、授权撤销、HID 退避暂停、过期锁屏截止、坏更新缓存、设置迁移、SMC 重建和 GPU 缺失值
- 键盘与滑杆混用的已构造交错没有复现“旧滑杆成为最终值”，保留原调度实现并增加双向回归用例

## 剩余工作与实机边界

1. **已确认的语言完整性问题**：应用语言只注入 SwiftUI locale，部分 `String(localized:)` 和硬编码中文仍跟随系统语言。需统一 View、模型与状态文案的本地化入口，单独完成语言切换改造。
2. **窗口生命周期补验**：设置关闭期间在系统设置中改变锁屏参数、输入尚未完成时退出、重开后的焦点和草稿状态需要更完整的 UI 验证。
3. **实机验收**：真实外屏快速拔插、断电重启、多外屏、睡眠登录优先级，以及鼠标权限撤销后的真实事件恢复。本轮使用假硬件回归测试验证这些状态机，未实际制造这些系统事件。
4. **兼容性**：本地验证使用 macOS 27；新增改动的 macOS 26 运行结果依赖后续 CI 和对应实机。
5. **性能**：未运行 Instruments 长时对照。测试夹具仍有阻塞等待造成的 QoS 诊断，后续可改用异步等待。

本报告不对尚未实测的硬件路径或完整双语界面作通过保证。
