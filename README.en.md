# Fanshu Monitor

> A macOS menu bar system monitor and external display control utility for Apple Silicon.

<p align="center">
  <img src="docs/images/icon-128.png" width="112" alt="Fanshu Monitor logo">
</p>

<p align="center">
  <a href="https://louis16s.github.io/fanshu_monitor/">Website</a> ·
  <a href="https://github.com/louis16s/fanshu_monitor/releases">Download</a> ·
  <a href="README.md">中文</a>
</p>

## Overview

Fanshu Monitor is a lightweight macOS menu bar app for watching CPU, GPU, memory, battery, network, and display status. The direct distribution build also includes external display control: it can take over F1/F2 brightness keys based on the screen under your pointer, then show the native macOS brightness OSD when a controllable external display is targeted.

The project is still moving quickly. The goal is simple: useful monitoring and display controls without making a resident menu bar app feel heavy.

## Features

- Live menu bar monitoring for CPU, GPU, memory, battery, storage, and network.
- Core metrics such as CPU temperature, GPU utilization, memory pressure, and the app's own memory footprint.
- External display brightness control with pointer-based target selection.
- Native macOS brightness OSD when available.
- Per-display capability status and clear unsupported reasons.
- HiDPI controls for external displays.
- Hidden monitor modules stop sampling.
- Lower sampling frequency while the panel is closed.
- Update checking toggle, manual update check, settings reset, and practical utility actions.

## Screenshot

If GitHub image caching is temporarily unavailable, open the [website](https://louis16s.github.io/fanshu_monitor/) for the full showcase.

<p align="center">
  <img src="docs/images/current-panel.png" width="360" alt="Fanshu Monitor panel screenshot">
</p>

## Installation

1. Open [Releases](https://github.com/louis16s/fanshu_monitor/releases).
2. Download the latest `番薯Monitor.zip` or app attachment.
3. Unzip and move `番薯Monitor.app` to `Applications`.
4. Grant Accessibility permission on first launch so F1/F2 brightness key takeover can work.

If macOS blocks the unsigned app, run:

```bash
sudo xattr -cr /Applications/番薯Monitor.app
```

## Requirements

- Apple Silicon Mac
- macOS 26 or later

## Build

```bash
xcodebuild -project 番薯monitor.xcodeproj -scheme 番薯Monitor -configuration Debug build
```

Release build:

```bash
xcodebuild -project 番薯monitor.xcodeproj -scheme 番薯Monitor -configuration Release build
```

## Website Deployment

The GitHub Pages site lives in `docs/`. In the GitHub repository, open `Settings` → `Pages`, choose `Deploy from a branch`, select `main`, and set the directory to `/docs`.

Final URL:

```text
https://louis16s.github.io/fanshu_monitor/
```

## License

MIT
