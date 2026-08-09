# Security

## Supported Releases

Only assets published on the official [GitHub Releases](https://github.com/louis16s/fanshu_monitor/releases) page are supported.

Each automated release includes `FanshuMonitor.zip`, `checksums.txt`, and `release-manifest.json`. The manifest binds the artifact SHA-256 to the release version and source commit. Verify the archive before opening it:

```bash
shasum -a 256 -c checksums.txt
```

## Release Trust

The release workflow requires Developer ID signing and Apple notarization. It refuses to publish an ad-hoc signed archive when release credentials are unavailable. Configure these encrypted GitHub Actions secrets before pushing a release tag:

- `APPLE_CERTIFICATE_P12`: base64-encoded Developer ID Application certificate and private key
- `APPLE_CERTIFICATE_PASSWORD`: password protecting the PKCS#12 archive
- `APPLE_NOTARY_PRIVATE_KEY`: App Store Connect API private key contents
- `APPLE_NOTARY_KEY_ID`: App Store Connect API key ID
- `APPLE_NOTARY_ISSUER_ID`: App Store Connect issuer ID

Successful releases are signed with Hardened Runtime, submitted to Apple's notary service, stapled, assessed with Gatekeeper, and published with checksums and a source manifest.

Locally produced development builds can be inspected with:

```bash
codesign -dv --verbose=4 /Applications/番薯Monitor.app
spctl --assess --type execute --verbose=4 /Applications/番薯Monitor.app
```

## Permissions And Local Data

- Accessibility and Input Monitoring are used only for optional F1/F2 takeover and mouse button mapping.
- The Codex quota module reads `~/.codex/auth.json` only when the module is enabled, then sends its access token to `https://chatgpt.com/backend-api/wham/usage` to retrieve quota data.
- While the panel is open and the Codex module is visible, task progress reads conversation names from `~/.codex/session_index.jsonl`. For a small set of recent local `~/.codex/sessions` rollout files it searches backward in 1 MiB chunks, up to 16 MiB, only until the latest task boundary is found; after that it follows appended bytes only. This data stays on the Mac and is never uploaded by Fanshu Monitor.
- DDC, SMC, IOKit, and Logitech HID++ integrations access local hardware only.

## Reporting A Vulnerability

Please do not publish credential exposure, privilege escalation, or arbitrary code execution details in a public issue first. Use GitHub's private vulnerability reporting feature for this repository when available, or contact the maintainer through the repository owner profile with a minimal reproduction and affected version.
