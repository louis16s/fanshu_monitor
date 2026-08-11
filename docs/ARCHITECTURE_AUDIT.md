# 架构审查清单

更新日期：2026-08-11

## 审查结论

- 最近一次完整发布审查基于 `0.3.1`，最后一台外接屏拔除后的内屏恢复已完成真实硬件验证
- 单元测试、Release 静态分析、签名校验和本机启动检查通过
- GitHub Actions 可由 `v*` tag 自动测试、构建、打包并创建 Release
- 云端产物使用临时签名保证包内完整性，尚未配置 Developer ID 签名与 Apple 公证

## 架构分层

- App/UI：SwiftUI 菜单栏面板、设置窗口和共享视觉组件
- 状态层：`MonitorStore` 发布界面状态并调度刷新
- 采样层：`SamplingCoordinator` actor 管理 worker 生命周期、取消和结果合并
- 采样器：`SamplingCoordinator` 按可见模块懒加载独立的 `MonitorModuleSamplerWorker`
- 功能控制器：显示器、鼠标、锁屏、Codex 和更新检查彼此独立
- 硬件桥接：DDC、DisplayServices、SMC、IOKit 与 HID 显式脱离主 actor，并在后台串行队列执行
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
- [x] 面板关闭时主调度器降至 5 秒检查间隔
- [x] 软件调光配置和内建屏拓扑状态使用锁保护，避免跨队列竞争

## 显示器可靠性

- [x] F1/F2 根据鼠标所在屏幕选择目标
- [x] 内建屏和不可控屏放行系统原生快捷键
- [x] 外接 DDC 写入按显示器串行
- [x] 滑杆写入合并，键盘档位写入保持顺序
- [x] DDC 故障熔断按显示器和控制项隔离
- [x] DDC 拓扑探测单独串行，连续插拔不会让旧探测覆盖新拓扑
- [x] 慢速 DDC 探测不阻塞其他显示器的原生亮度读写
- [x] 屏幕重排、插拔和唤醒会刷新显示器映射
- [x] Apple Silicon 外接屏拔除由独立 IOKit DCP 服务监听确认，不依赖单一 WindowServer 回调
- [x] 多外屏与快速重插会重新确认外接硬件服务数量，不会误恢复内建屏
- [x] IOKit 原始事件、去抖和最终断开确认封装在硬件监视器中，显示控制器只执行高层恢复动作
- [x] 拔除最后一台外接屏后，真实硬件测试在约 369 毫秒内恢复内建屏并设置 35% 亮度
- [x] 内屏隔离与外接断开恢复使用成对的持久拓扑事务，登录窗口不会先回到内屏优先
- [x] 外接 DCP 服务接入后走独立拓扑快速通道，不等待 DDC 探测即恢复外接优先
- [x] 原生亮度读取等待同屏写入完成
- [x] 过期读取和过期写入结果不会覆盖最新状态

## 安全与发布

- [x] 仓库不包含 SSH 私钥、令牌或发布凭据
- [x] GitHub Actions 第三方 action 固定到提交 SHA
- [x] tag 必须与 `MARKETING_VERSION` 一致
- [x] Release 前运行完整测试
- [x] Release 生成 SHA-256 和 JSON manifest
- [ ] 配置 Developer ID Application 证书
- [ ] 配置 Apple 公证凭据并在发布后 stapler 验证

## 后续建议

1. 配置 Developer ID 与公证，消除首次下载时的 Gatekeeper 信任提示
2. 为真实 DDC 显示器建立可选硬件回归测试台，覆盖不同 VCP 范围和超时设备
3. 用 Instruments 定期记录面板打开与关闭时的 CPU、唤醒次数和常驻内存
