# 番薯Monitor

> 面向 Apple Silicon 的 macOS 菜单栏系统监控与外接显示器控制工具。

<p align="center">
  <img src="docs/images/icon-128.png" width="112" alt="番薯Monitor logo">
</p>

<p align="center">
  <a href="https://louis16s.github.io/fanshu_monitor/">官网</a> ·
  <a href="https://github.com/louis16s/fanshu_monitor/releases">下载</a> ·
  <a href="README.en.md">English</a>
</p>

## 简介

番薯Monitor 是一个轻量的 macOS 菜单栏应用，用来观察 CPU、GPU、内存、电池、网络和显示器状态。直发版本加入了外接显示器控制能力，可以根据鼠标所在屏幕接管 F1/F2 亮度键，并在可控外接屏上显示系统原生亮度浮层。

当前版本仍在快速迭代，目标是：功能足够丰富，但长期常驻时保持低开销。

## 功能

- 菜单栏实时监控 CPU、GPU、内存、电池、存储和网络。
- CPU 温度、GPU 利用率、内存压力、App 自身内存占用等核心指标。
- 外接显示器亮度控制，支持按鼠标所在屏幕选择控制目标。
- 可用时显示 macOS 原生亮度 OSD。
- 显示每台屏幕的控制能力和不可控原因。
- 外接屏 HiDPI 控制入口。
- 监控模块可隐藏；隐藏后停止对应采样。
- 面板关闭时降低采样频率，减少常驻开销。
- 自动检查更新开关、手动检查更新、设置重置等实用操作。

## 截图

如果 GitHub 图片缓存暂时不可用，可以直接访问 [官网](https://louis16s.github.io/fanshu_monitor/) 查看完整展示。

<p align="center">
  <img src="docs/images/current-panel.png" width="360" alt="番薯Monitor 面板截图">
</p>

## 安装

1. 打开 [Releases](https://github.com/louis16s/fanshu_monitor/releases)。
2. 下载最新版本的 `番薯Monitor.zip` 或应用附件。
3. 解压后将 `番薯Monitor.app` 移到 `Applications`。
4. 首次启动后授予辅助功能权限，用于接管 F1/F2 亮度键。

如果 macOS 因未公证而阻止打开，可以执行：

```bash
sudo xattr -cr /Applications/番薯Monitor.app
```

## 系统要求

- Apple Silicon Mac
- macOS 26 或更高版本

## 构建

```bash
xcodebuild -project 番薯monitor.xcodeproj -scheme 番薯Monitor -configuration Debug build
```

Release 构建：

```bash
xcodebuild -project 番薯monitor.xcodeproj -scheme 番薯Monitor -configuration Release build
```

## 官网部署

官网文件位于 `docs/`。在 GitHub 仓库中进入 `Settings` → `Pages`，选择 `Deploy from a branch`，分支选 `main`，目录选 `/docs`。

部署后地址：

```text
https://louis16s.github.io/fanshu_monitor/
```

## 许可证

MIT
