# 番薯Monitor 面板设计规范

本文件是面板 UI 的长期约束。新增或修改 CPU、GPU、UMA、Power、Codex、Network、Storage、Display 等模块时必须遵守，避免各模块形成独立样式。

## 标题行

- 所有模块统一使用 `PanelModuleHeader`
- 图标统一使用 `PanelModuleIcon`
- 标题和主值统一为 12 pt、SF Pro、Semibold
- 主值只启用等宽数字，不把英文字母切换成等宽字体
- 字距固定为 0，不允许模块单独设置 `kerning` 或 `tracking`
- 图标尺寸为 13 pt，图标槽宽 18 pt
- 图标与文本区域间距为 10 pt，标题与主值间距为 6 pt
- 标题行水平内边距为 10 pt，垂直内边距为 8 pt
- 标题颜色、主值颜色和尾部控件通过共享组件参数传入
- 折叠箭头、进度条、曲线、功率值等尾部内容只能放入 `trailing` 插槽

## 代码归属

- 字体常量只在 `FanshuMonitor/Views/Panel/PanelTextStyles.swift` 修改
- 标题结构和间距只在 `FanshuMonitor/Views/Panel/PanelModuleHeader.swift` 修改
- 模块文件不得为标题行重复声明字号、字重、图标槽、内边距、`fixedSize` 或 `layoutPriority`
- 详情指标优先复用共享双列网格，不为单个模块复制一套排版
- 需要特例时先扩展共享组件，并在代码中说明特例适用于哪些模块

## 视觉检查

- CPU、GPU、UMA、Power、Codex、Display 同屏时，标题基线、字号、字重和左侧图标槽必须一致
- 普通监控模块的英文标题统一由 `MonitorKind.panelTitle` 提供，视图不得重复硬编码
- 中英文标题混排时保持同一字号和字重，不用额外字距补偿视觉大小
- 长标题只能压缩尾部辅助内容或使用最小缩放，不能撑高标题行
- 禁用模块的图标和文字要明显变灰并显示删除线
- Display 模块保持紧凑，亮度滑杆保留清晰底轨和 DDC 0 数字刻度

## 验证

每次修改面板共享组件后至少执行：

```bash
./script/build_and_run.sh --verify
```

并实际打开面板检查浅色、深色以及包含 Display 的完整布局。成功构建的 app 必须刷新到 `outputs/番薯Monitor.app`。

## 锁屏行为

- 分时锁屏到点后直接进入 macOS 登录锁定界面，不经过屏保
- 分时锁屏启用期间关闭系统空闲屏保，由一次性计时器按当前规则触发锁定
- 空闲计时只在规则切换、设置变化、唤醒、解锁和计时到点时检查，禁止每秒轮询
- 关闭分时锁屏时恢复启用前的系统屏保设置
