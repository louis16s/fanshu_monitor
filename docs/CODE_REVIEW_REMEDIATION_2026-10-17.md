# 代码审查问题修复记录

对应审查：`CODE_REVIEW_2026-10-17.md`
修复基线：`0bb0ab7`
处理日期：2026-10-17

## 已修复

- H1：镜像配置完成后，失败路径不再对已消费的 `CGDisplayConfigRef` 再次 cancel。
- M1 / M2：系统锁屏设置只提交用户编辑过的字段；系统未提供的值不会被界面默认值覆盖。屏保时间 `0` 表示关闭，密码字段可独立修改。
- M3：电源事件停止时先撤销通知并排空串行回调队列，再关闭 root port；显示拓扑 bridge 对异步回调上下文保留对象直到通知端口销毁后的主队列排空点。
- M4：Codex 配额内容不变时仍会刷新缓存时间；时间显示精度为分钟，因此同一分钟内避免重复写入缓存。
- M5：DPI“设定”使用输入框当前文本并走统一校验、限幅和提交流程。
- L7：授权状态改为在设置页出现和应用重新激活时查询，不在 View 初始化期间查询。
- L8：自绘 DPI 滑杆补上 VoiceOver 标签、当前值和增减动作。
- L10：SMC 四字符码解析移除外部字节的强制解包。

## 经评估后保留

- M6：DDC 通道达到最大恢复次数后继续隔离，是防止底层永久阻塞时不断创建新队列/任务的资源上限。现有显示器服务重建和显式 reset 会清理隔离状态。本次不改成无限自动重试；若用户反馈设备长期无法恢复，应结合具体显示器日志再调整熔断恢复策略。
- 其余低优先级项目没有足够证据证明会造成当前用户可见故障，或修改需要独立的交互/硬件验证，因此不在本次扩展改动范围内。包括刷新节流、探测缓存策略和其它事件 tap 生命周期路径。

## 验证

- `xcodebuild test -project '番薯monitor.xcodeproj' -scheme '番薯Monitor' -destination 'platform=macOS' -parallel-testing-enabled NO`：333 项通过。
- `xcodebuild analyze -project '番薯monitor.xcodeproj' -scheme '番薯Monitor' -configuration Release -destination 'platform=macOS'`：通过，零 warning。
- 尚未对多种真实显示器、反复休眠/唤醒和长期阻塞 DDC 硬件做实机压力验证。
