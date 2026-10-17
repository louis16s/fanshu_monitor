# 第二轮代码审查修复记录

对应审查：`CODE_REVIEW_2026-10-17-r2.md`
修复基线：`7bfc8e8`
处理日期：2026-10-17

## 已处理

- N1 / N2：电源与显示拓扑 IOKit bridge 改用独立 callback context；context 弱引用 bridge，避免 UAF 和 refcon 对象自持泄漏。停止时先解除通知并销毁端口，再把 context 释放排到对应回调队列，电源桥关闭 root port 也在该串行队列完成，不再同步阻塞主线程。
- N3：移除无人调用的整体覆盖写 `ScreenSaverLockPreferences.apply`，只保留逐字段更新路径。
- N4：系统没有提供 `idleTime` 时，文本框显示空值和“系统默认”占位，不再误显示 10 分钟。
- N5：缓存 Codex 时间格式器，避免每次展示或比较时间都重新构造 `DateFormatter`。
- L1：亮度键 event tap 停止时显式 invalidate Mach port；对象生命周期仍由主 actor 控制器管理。
- L6：Codex usage client 增加可注入时钟，解析的 `fetchedAt` 不再直接读取系统 `Date()`。
- L9：Codex 空状态占位指标改为与实际额度模型一致。
- L8 之外的上一轮修复继续保留。

## 经评估后保留或澄清

- M6：继续保留 DDC 最大恢复次数。超时的底层硬件调用无法取消；周期性重新创建 transport 队列会让旧的卡住调用长期累积。服务替换、显示器拓扑变化和唤醒时现有逻辑会重置隔离。若实机证明同一服务长期卡在熔断状态，再考虑带总量上限的探测恢复。
- 原报告 L9 对旧 Codex 指标的判断在修复前成立，本轮已修复并增加占位字段断言。
- `UpdateChecker.swift` 与其测试的既有未提交改动不属于这轮范围，未修改、未暂存、未提交。
- 其余 L1 相关 `MainActor.assumeIsolated` 路径未改变：当前 tap 由主 actor 控制器创建和停止；若未来改变所有权或支持跨 actor 销毁，需单独替换为隔离显式的释放机制。

## 验证

- 全量测试：334 项通过。
- Release 静态分析：通过，零 warning。
- `./script/build_and_run.sh --verify`：Release 构建通过，签名验证通过，`outputs/番薯Monitor.app` 的 `0.3.4` 已启动。
- IOKit 竞争时序仍建议通过真实睡眠/唤醒和外接显示器反复连接场景长期观察；单元测试无法模拟内核通知投递的全部竞态。
