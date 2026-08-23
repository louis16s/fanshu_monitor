# 架构审查清单

更新日期：2026-08-23

## 审查结论

- 最近一次完整发布审查基于 `0.3.2`，最后一台外接屏拔除后的内屏恢复已完成真实硬件验证
- 完整单元测试、Direct Target 构建和 Release 静态分析通过
- UI 测试 bundle 构建通过；本轮本机 XCTest UI runner 未完成执行，未将其计为通过
- GitHub Actions 在 main 与 pull request 执行日常验证，`v*` tag 负责签名、公证、打包和创建 Release
- Release workflow 强制要求 Developer ID Application 和 Apple notary 凭据，缺失时拒绝发布

## 架构分层

- App/UI：SwiftUI 菜单栏面板、设置窗口和共享视觉组件
- 状态层：`MonitorStore` 发布运行状态并调度刷新，App 与面板直接观察共享的 `MonitorSettings`，避免设置变化触发整个 Store 刷新
- 主线程边界：`MonitorStore`、`MonitorSettings` 和锁屏策略显式运行在 `MainActor`；采样 worker、Codex 读取和硬件桥接留在 actor 或串行后台边界
- 指标边界：`MetricID` 贯穿设置、采样上下文、采样器和面板，落盘时仍使用原始字符串以兼容旧设置
- Codex 活动任务使用独立的 `codexTasks` 状态流，不再伪装成动态 `MonitorMetric` 或污染额度缓存
- 采样层：`SamplingCoordinator` actor 管理 worker 生命周期、取消和结果合并
- 采样器：`SamplingCoordinator` 按可见模块懒加载独立的 `MonitorModuleSamplerWorker`
- 功能控制器：显示器、鼠标、锁屏、Codex 和更新检查彼此独立，显示器 MainActor 状态与后台 `DisplayControlWorker` 分文件维护
- 硬件桥接：DDC、DisplayServices、SMC、IOKit 与 HID 显式脱离主 actor，并在后台串行队列执行
- 显示器私有能力：CoreDisplay、DisplayServices、IOAVService 与 OSD 统一通过 `PrivateDisplayAPI` 运行时解析，缺失时只关闭对应能力，不阻止应用启动
- 工程目标：只保留正式 `FanshuMonitorDirect` app target，测试、CI 与 Release 共用同一产品边界
- 系统能力：私有锁屏与显示器隔离符号统一登记到 `SystemCapabilityRegistry`，缺失时保留明确的降级状态
- 持久化：`MonitorSettings` 只声明设置行为，JSON 编解码由 `PreferencesCodec` 统一处理和记录错误
- 设置持久化：`MonitorSettingsPersistence` 集中管理 Combine 绑定、UserDefaults 写入和登录项更新，保留原有 key 与迁移行为
- 面板 View：通用、存储、网络和电源行分文件维护，共享 `PanelModuleHeader` 与详情网格
- 发布层：tag、Release workflow、SHA-256 清单和 release manifest

## 性能清单

- [x] 隐藏监控模块后释放对应采样器
- [x] 网络面板关闭后停止采样，作为菜单栏圆环来源时仅保留轻量采样
- [x] 鼠标未连接时停止按钮 event tap 与 HID++ 监听
- [x] DPI、DDC 与原生显示器访问不在 SwiftUI 主线程执行
- [x] 外接显示器只读取已启用的 DDC 控制项
- [x] 内建亮度同步仅在面板打开、Display 可见且亮度控制开启时运行
- [x] 内建亮度以 200 毫秒低成本读取同步，不访问 DDC、IOKit 或磁盘
- [x] 内建亮度同步停止后不保留计时任务
- [x] 亮度未变化时不发布 SwiftUI 状态更新
- [x] 相同显示器发现结果不重复发布，合并的拓扑回调不会触发无意义的面板重绘
- [x] 面板可见性桥接延后到 SwiftUI 更新周期之后发布状态，避免视图更新期间重入
- [x] 面板关闭时主调度器降至 5 秒检查间隔
- [x] 指标开关变化只重置受影响模块的刷新预约，不再让所有模块立即重复采样
- [x] 采样器生命周期更新带 generation guard，旧的异步释放请求不能覆盖最新可见模块状态
- [x] 网络接口临时读取失败保留最后一次有效值，并对同一轮失败限频记录
- [x] 软件调光配置和内建屏拓扑状态使用锁保护，避免跨队列竞争
- [x] Codex session index 使用进程内偏移量增量读取，不重复读取完整索引或写入额外缓存
- [x] Codex rollout 增量读取保留未完成 JSONL 行，分段写入不会丢失任务结束或计划更新事件
- [x] Codex 计划读取支持当前 `function_call/name/arguments` 事件结构，并以结构化 JSON 解析步骤
- [x] Codex 活动任务变化只发布任务状态，不再重建整个模块指标数组
- [x] Codex 额度刷新只合并 Codex 模块，迟到的网络结果不会用旧快照覆盖 CPU、GPU、UMA 和电源数据
- [x] 电池 Smart Battery 详情只在面板可见且健康度、循环数或温度至少一项启用时读取
- [x] 指标设置按稳定顺序落盘，避免 `Set` 顺序造成无意义写入差异

## 显示器可靠性

- [x] F1/F2 根据鼠标所在屏幕选择目标
- [x] 内建屏和不可控屏放行系统原生快捷键
- [x] 外接 DDC 写入按显示器串行
- [x] 滑杆写入合并，键盘档位写入保持顺序
- [x] DDC 故障熔断按显示器和控制项隔离
- [x] DDC 拓扑探测单独串行，连续插拔不会让旧探测覆盖新拓扑
- [x] 相同显示器发现请求共享在途结果，过期请求只补跑最新一次硬件扫描
- [x] 慢速 DDC 探测不阻塞其他显示器的原生亮度读写
- [x] 屏幕重排、插拔和唤醒会刷新显示器映射
- [x] Apple Silicon 外接屏拔除由独立 IOKit DCP 服务监听确认，不依赖单一 WindowServer 回调
- [x] 多外屏与快速重插会重新确认外接硬件服务数量，不会误恢复内建屏
- [x] IOKit 原始事件、去抖和最终断开确认封装在硬件监视器中，显示控制器只执行高层恢复动作
- [x] 拔除最后一台外接屏后，真实硬件测试在约 369 毫秒内恢复内建屏并设置 35% 亮度
- [x] 内屏隔离与外接断开恢复使用成对的持久拓扑事务，登录窗口不会先回到内屏优先
- [x] 外接 DCP 接入和睡眠唤醒共用单一拓扑协调器，不等待 DDC 探测且成功后立即停止剩余重试
- [x] IOKit、NSWorkspace 与硬件接入通知重叠时不会并发重复配置
- [x] 安全恢复 watchdog 在外接硬件服务仍存在时不提交内屏恢复，避免 WindowServer 拓扑竞争
- [x] 内建屏已经处于隔离状态时只登记状态，不重复提交相同的私有显示器配置
- [x] 在线但休眠的内建屏不会被误判为已隔离，避免 watchdog 反复提交 SkyLight 拓扑恢复
- [x] 原生亮度读取等待同屏写入完成
- [x] 过期读取和过期写入结果不会覆盖最新状态

## DDC 与 Gamma 亮度链路

- [x] 用户亮度先映射到 DDC 有效范围，硬件下限仍统一呈现为用户侧 0%
- [x] 外接屏低于 DDC 硬件下限时使用独立 `DisplayGammaService` 调整输出传输曲线
- [x] Gamma 基线按显示器保存，不共享不同显示器的色彩表
- [x] Gamma 只在亮度变化或显示器生命周期变化时写入，不进入高频指标采样循环
- [x] 亮度恢复、显示器断开和服务清理时恢复原始 Gamma 表
- [x] Gamma 基线读取失败时才启用黑色覆盖层降级，覆盖层设置为不可参与窗口共享，避免常规截图捕获覆盖层
- [x] 内建显示器保持系统原生亮度路径，不应用外接屏 Gamma 补偿
- [x] Gamma 硬件调用通过可注入桥接层串行执行，核心映射和恢复路径可脱离真实显示器测试
- [x] 临时不完整的显示器列表不会丢弃仍在线屏幕的 Gamma 基线，避免重复压暗
- [x] 休眠前恢复系统色彩曲线并取消过期调光请求，唤醒后的最新拓扑刷新再应用用户值
- [x] 正常退出和 SIGTERM 共用完整显示器清理路径，同时恢复 Gamma 与内建屏拓扑
- [x] 单屏 Gamma 恢复失败时回退到 ColorSync 配置，避免应用退出后残留调光曲线
- [x] DDC IOKit 枚举遇到无名注册项时释放对象并继续扫描，避免泄漏和遗漏后续服务

Gamma 是显示输出层补偿，不会改变 DDC 硬件寄存器，也不会伪造系统原生 OSD 的数值。部分显示器、Night Shift、其他色彩管理工具或系统显示服务可能拒绝或覆盖传输表；这种情况下应用保留降级路径，并在真实硬件回归中确认截图和色彩管理行为

## 本轮阶段一、二改动

- [x] `SamplingCoordinator` 继续作为采样 worker 的唯一生命周期入口，`MonitorStore` 只负责主线程状态和调度
- [x] `MonitorSettingsPersistence` 从设置声明中拆出，减少设置模型的职责范围
- [x] 显示器软件调光、内屏隔离和 DisplayServices 桥接拆为独立硬件服务文件，保留 `DisplayControlService` 外部 API
- [x] 锁屏系统通知、睡眠唤醒、电源源和 watchdog 拆为 `LockScreenSystemObserver`，策略判断仍由 `LockScreenPolicyController` 负责
- [x] 删除退出时强制 `UserDefaults.synchronize()`，避免不必要的同步磁盘写入

## 本轮阶段三改动

- [x] DDC 故障熔断器支持注入时钟，冷却窗口和读写故障历史可在单元测试中确定性验证
- [x] CI 不再只构建 UI 测试 bundle，新增真实 UI 启动冒烟测试
- [x] UI 测试失败时保留 `.xcresult` 和日志，降低菜单栏应用启动问题的定位成本
- [x] 新增 `docs/TESTING.md`，区分 CI、单元测试、真实硬件回归和 Instruments 性能验证

## 安全与发布

- [x] 仓库不包含 SSH 私钥、令牌或发布凭据
- [x] GitHub Actions 第三方 action 固定到提交 SHA
- [x] tag 必须与 `MARKETING_VERSION` 一致
- [x] Release 前运行完整测试
- [x] Release 生成 SHA-256 和 JSON manifest
- [x] Release 强制使用 Developer ID Application 签名
- [x] Release 提交 Apple 公证并执行 stapler 验证
- [x] 私有显示器框架不再直接链接，Release 不依赖当前系统是否暴露对应链接目标
- [x] 更新检查使用独立的 ephemeral 会话，不共享 Cookie 或磁盘 URL 缓存
- [x] 本地文件和系统错误详情在 Unified Logging 中默认脱敏

## 后续建议

1. 为真实 DDC 显示器建立可选硬件回归测试台，覆盖不同 VCP 范围和超时设备
2. 用 Instruments 定期记录面板打开与关闭时的 CPU、唤醒次数和常驻内存
3. 在 UI runner 环境稳定后补跑设置窗口启动与导航用例
4. 将 `DisplayControlController` 与锁屏设置大 View 继续按状态机和页面组件渐进拆分，避免一次性重写影响已验证硬件流程
