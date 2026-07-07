# 番薯Monitor

面向 Apple Silicon 的 macOS 菜单栏系统监控与外接显示器控制工具。

<p align="center">
  <img src="docs/images/icon-128.png" width="112" alt="番薯Monitor logo">
</p>

<p align="center">
  <a href="https://louis16s.github.io/fanshu_monitor/">官网</a> ·
  <a href="https://github.com/louis16s/fanshu_monitor/releases">下载</a> ·
  <a href="README.en.md">English</a>
</p>

## 系统要求

- Apple Silicon Mac
- 最低系统版本：macOS 26.0
- 外接显示器亮度控制需要支持 DDC/CI 的显示器、线缆和连接方式
- F1/F2 接管、鼠标按键映射等功能需要授予辅助功能权限

## 简介

番薯Monitor 是一个轻量常驻的菜单栏应用，用来观察 CPU、GPU、内存、电池、Codex 额度、鼠标和显示器状态。直发版本支持根据鼠标所在屏幕接管 F1/F2 亮度键，在可控外接屏上调整 DDC 亮度，并尽量显示系统原生亮度浮层。

当前版本：`0.2.6`

## 主要功能

- 菜单栏面板显示 CPU、GPU、内存、电池、Codex 额度和显示器状态
- 根据鼠标所在屏幕控制外接显示器亮度
- 内建屏和不可控外接屏会把 F1/F2 交回 macOS
- 显示每台屏幕的控制能力、DDC 状态和不可控原因
- 隐藏模块停止对应采样，面板关闭后降低采样频率
- 内存面板显示 App 自身内存占用，便于观察常驻开销
- 鼠标页支持 MX Anywhere 3S DPI 读取、设定和按键映射
- 关于页提供更新检查、项目链接和参考项目说明

## 截图

如果 GitHub 图片缓存暂时不可用，可以直接访问 [官网](https://louis16s.github.io/fanshu_monitor/) 查看完整展示。

<p align="center">
  <img src="docs/images/current-panel.png" width="390" alt="番薯Monitor 面板截图">
</p>

<p align="center">
  <img src="docs/images/settings-about.png" width="680" alt="番薯Monitor 关于设置截图">
</p>

<p align="center">
  <img src="docs/images/settings-mouse.png" width="680" alt="番薯Monitor 鼠标设置截图">
</p>

## 安装

1. 打开 [Releases](https://github.com/louis16s/fanshu_monitor/releases)
2. 下载最新版本的 `FanshuMonitor.zip`
3. 解压后将里面的 `番薯Monitor.app` 移到 `Applications`
4. 首次启动后授予辅助功能权限

如果 macOS 因未公证而阻止打开，可以执行：

```bash
sudo xattr -cr /Applications/番薯Monitor.app
```

## 构建

推荐使用项目内统一脚本，它会构建 Release、刷新 `outputs/番薯Monitor.app` 和 `outputs/番薯Monitor.zip`，并打开新版应用：

```bash
./script/build_and_run.sh --verify
```

也可以直接使用 Xcode：

```bash
xcodebuild -project 番薯monitor.xcodeproj -scheme 番薯Monitor -configuration Release -destination 'platform=macOS' build
```

## 官网部署

官网文件位于 `docs/`。在 GitHub 仓库中进入 `Settings` → `Pages`，选择 `Deploy from a branch`，分支选 `main`，目录选 `/docs`。

部署后地址：

```text
https://louis16s.github.io/fanshu_monitor/
```

## 许可证

本项目使用 [MIT License](LICENSE)。

项目中吸收或参考了 MonitorControl、Hagimi Monitor、Mouser 等开源项目的思路和部分实现。第三方许可与来源说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
