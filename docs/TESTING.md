# 测试与验证

## CI 门槛

每次推送到 `main` 或创建 Pull Request 时，GitHub Actions 会执行：

1. Direct target 单元测试
2. Direct app Debug 构建
3. UI 测试 bundle 构建
4. UI 启动冒烟测试
5. Direct app 静态分析

UI 测试失败时会保留 `.xcresult` 和日志，方便定位启动、权限提示或菜单栏应用退出问题

## 本地验证

```sh
xcodebuild \
  -project '番薯monitor.xcodeproj' \
  -scheme '番薯Monitor' \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild \
  -project '番薯monitor.xcodeproj' \
  -scheme '番薯Monitor UI Tests' \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  test
```

UI runner 需要当前用户允许 Xcode 或 `FanshuMonitorUITests-Runner` 使用辅助功能和自动化控制。若本机没有该权限，测试会在启动阶段超时；这属于测试环境权限失败，不代表应用逻辑测试失败。GitHub Actions 使用临时 ad hoc 签名执行同一条 UI 冒烟路径

真实硬件验证使用 `./script/build_and_run.sh --verify`，不会把测试版应用复制到系统应用目录

## 硬件回归矩阵

以下场景需要在实际 Apple Silicon Mac 上验证，不适合强行放入 CI：

- 外接 DDC 屏幕读写、VCP 最小值、0% 映射和 DDC 超时熔断
- F1/F2 在内建屏、可控外接屏和不可控屏之间切换目标
- 辅助功能权限首次授权、撤销后重新授权和应用重启
- 显示器排列变化、拔出最后一台外接屏、快速重插
- 睡眠、唤醒、登录窗口显示器优先级和内建屏恢复
- 内建显示器关闭后保持列表项，之后手动恢复并还原亮度
- HID 鼠标连接、断开、电量变化和按键映射
- 电源接通、断开、快速功率变化和功率分流动画
- 外接屏 DDC 下限以下的 Gamma 调光、截图结果和恢复到 100% 后的原始色彩表
- Gamma 与 Night Shift、其他显示器调光软件同时存在时的能力降级和恢复

每次硬件回归记录：macOS 版本、芯片型号、显示器型号、连接方式、权限状态、触发步骤、预期结果和实际耗时

Gamma 回归还应记录：显示器原始亮度范围、截图是否仍能看到低于 DDC 下限的调光效果、切换到 100% 后颜色是否恢复、睡眠唤醒和拔插后是否重新捕获基线

## 性能验证

使用 Instruments 的 Time Profiler、Energy Log 和 Allocations 分别记录：

- 面板打开 60 秒
- 面板关闭且应用常驻 60 秒
- 显示器插拔和睡眠唤醒各一次
- Codex、网络、存储和电池重遥测开启与关闭的对照

重点观察主线程时间、唤醒次数、DDC 调用耗时、内存增长和磁盘写入次数。没有 Instruments 数据时，只报告静态结论，不把估算当成实测结果
