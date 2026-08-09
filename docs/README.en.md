# Fanshu Monitor

A macOS menu bar system monitor, external display controller, and scheduled lock utility for Apple Silicon.

<p align="center">
  <img src="images/icon-128.png" width="112" alt="Fanshu Monitor logo">
</p>

<p align="center">
  <a href="https://louis16s.github.io/fanshu_monitor/">Website</a> ·
  <a href="https://github.com/louis16s/fanshu_monitor/releases">Download</a> ·
  <a href="../README.md">中文</a>
</p>

## System Requirements

- Apple Silicon Mac
- Minimum macOS version: macOS 26.0
- External display brightness control requires a DDC/CI-capable display, cable, and connection path
- F1/F2 takeover and mouse button mapping require Accessibility permission

## Overview

Fanshu Monitor is a lightweight menu bar app for CPU, GPU, memory, power, Codex quota, mouse, and display status. It routes F1/F2 brightness keys to the display under your pointer, controls compatible external displays through DDC, and can lock macOS directly on different schedules throughout the day.

Current version: `0.3.0`

## Highlights

- Menu bar panel for CPU, GPU, UMA, battery, Codex quota, and display state
- Optional animated power flow whose direction and line weight reflect adapter input, system load, and battery charging or discharge
- macOS Shortcuts actions for reading live power flow and locking the screen immediately
- External display brightness target follows the pointer
- Built-in display brightness lightly syncs with the system value every 0.2 seconds
- Built-in and unsupported displays pass F1/F2 back to macOS
- Display capability, DDC state, and unsupported reasons are shown per display
- DDC failures are isolated per display with timeout circuit breaking and backoff
- Scheduled locking supports custom ranges, next-day times, independent idle limits, and per-rule pause
- Hidden modules stop sampling, and panel-closed refresh slows down
- Network, SSID, display discovery, heavy battery telemetry, and HID data load on demand
- UMA panel shows the app's own memory footprint
- Mouse settings support MX Anywhere 3S DPI reads, DPI apply, button mapping, and recorded custom shortcuts
- Codex shows plan, 5H and weekly quota, separate reset times, and every running conversation with its progress
- About settings include update checks, project links, and reference project notes

## Screenshots

This is the current `0.3.0` website and live panel preview. Open the [website](https://louis16s.github.io/fanshu_monitor/) to interact with the display, lock, mouse, and Codex demos.

<p align="center">
  <img src="images/site-preview.png" width="900" alt="Fanshu Monitor website and live panel preview">
</p>

## Install

1. Open [Releases](https://github.com/louis16s/fanshu_monitor/releases)
2. Download the latest `FanshuMonitor.zip`
3. Unzip and move the bundled `番薯Monitor.app` to `Applications`
4. Grant Accessibility permission on first launch

If macOS blocks the unsigned app, run:

```bash
sudo xattr -cr /Applications/番薯Monitor.app
```

## Build

Use the project script to build Release, refresh `outputs/番薯Monitor.app` and `outputs/番薯Monitor.zip`, then launch the new app:

```bash
./script/build_and_run.sh --verify
```

Or build with Xcode directly:

```bash
xcodebuild -project 番薯monitor.xcodeproj -scheme 番薯Monitor -configuration Release -destination 'platform=macOS' build
```

## Website Deployment

The GitHub Pages site lives in `docs/`. In the GitHub repository, open `Settings` → `Pages`, choose `Deploy from a branch`, select `main`, and set the directory to `/docs`.

Deployed URL:

```text
https://louis16s.github.io/fanshu_monitor/
```

## Brand Assets

The editable logo source is [`scripts/logo.html`](../scripts/logo.html), drawn entirely with HTML and CSS. App icons, website icons, and README assets are rendered from this single source.

## License

This project is licensed under the [MIT License](../LICENSE).

Fanshu Monitor incorporates or was informed by ideas and small portions of implementation from projects including MonitorControl, Hagimi Monitor, Mouser, and BatteryHarbor. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party license and source notes.

## Security

See [SECURITY.md](SECURITY.md) for permission, Codex quota, and release verification notes.
