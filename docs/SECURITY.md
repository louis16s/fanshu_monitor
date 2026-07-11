# Security

## Supported Releases

Only assets published on the official [GitHub Releases](https://github.com/louis16s/fanshu_monitor/releases) page are supported.

Each automated release includes `FanshuMonitor.zip`, `checksums.txt`, and `release-manifest.json`. The manifest binds the artifact SHA-256 to the release version and source commit. Verify the archive before opening it:

```bash
shasum -a 256 -c checksums.txt
```

## Current Distribution Status

The GitHub Actions build publishes a checksum, but Developer ID signing and Apple notarization require release credentials that are not stored in this repository. Until those credentials are configured, an automated GitHub Release archive must not be presented as signed or notarized.

Locally produced development builds can be inspected with:

```bash
codesign -dv --verbose=4 /Applications/番薯Monitor.app
spctl --assess --type execute --verbose=4 /Applications/番薯Monitor.app
```

## Permissions And Local Data

- Accessibility and Input Monitoring are used only for optional F1/F2 takeover and mouse button mapping.
- The Codex quota module reads `~/.codex/auth.json` only when the module is enabled, then sends its access token to `https://chatgpt.com/backend-api/wham/usage` to retrieve quota data.
- DDC, SMC, IOKit, and Logitech HID++ integrations access local hardware only.

## Reporting A Vulnerability

Please do not publish credential exposure, privilege escalation, or arbitrary code execution details in a public issue first. Use GitHub's private vulnerability reporting feature for this repository when available, or contact the maintainer through the repository owner profile with a minimal reproduction and affected version.
