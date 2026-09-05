# LLM Usage

[![Verify](https://github.com/agentik-os/llm-usage/actions/workflows/ci.yml/badge.svg)](https://github.com/agentik-os/llm-usage/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-black.svg)](LICENSE)

Your OpenAI accounts, usage and connected devices in the macOS menu bar.

LLM Usage is a native Swift app with a monochrome interface, Liquid Glass on macOS 26+, and a vibrancy fallback on macOS 13–15. Track multiple accounts, see their reset times, and choose which account your shared Codex connection uses.

## Features

- Browser sign-in with a short device code, plus a browser callback fallback.
- Multiple accounts together, with usage bars and reset dates in your local time zone.
- Editable account names and System, Light or Dark appearance independent of macOS.
- **Use this account** switches the shared Codex account without closing its conversations.
- Connected Macs and Linux VPS devices, with per-device confirmations and reconnect retries over SSH.
- Optional Hermes middleware for its native Codex Responses integration.

LLM Usage is an independent community project, not an official OpenAI or Apple product. It uses the locally installed Codex CLI and requires access to the relevant account features. Some app-server capabilities are experimental and may change between Codex versions.

## Build and install

Requirements:

- macOS 13 or newer to run; Xcode 26 or newer to build the native glass interface.
- A current Codex CLI with device-code authentication and app-server support. Tested on macOS with Codex 0.153.3; the Linux connector was tested with 0.150.1.
- Python 3.9+ for account sharing. Linux devices also need a working systemd user session and SSH access.

```sh
git clone https://github.com/agentik-os/llm-usage.git
cd llm-usage
./Scripts/package-app.sh
mkdir -p ~/Applications
ditto "dist/LLM Usage.app" "$HOME/Applications/LLM Usage.app"
open "$HOME/Applications/LLM Usage.app"
```

The script builds and locally signs `dist/LLM Usage.app`, and produces `dist/LLM-Usage-Connector.zip`. Locally signed builds are not Apple-notarized. The app icon is included in `Assets/`; its source drawing is `Scripts/make-icon.swift`.

LLM Usage was previously named QuotaBar. Existing bundle identifiers, Keychain entries, account storage paths, and connector service names retain their legacy identifiers so existing sign-ins and devices continue working.

## Add an account

Click the menu-bar gauge, then **Sign in with OpenAI**. Approve sign-in in your browser and enter the short code shown in LLM Usage. **Copy code** makes it easy to paste. Your account appears after approval; use **+** to add another.

If device-code login is unavailable for your account or workspace, choose **Use browser sign-in instead**. If loading is interrupted after approval, **Try again** resumes the saved connection.

The home screen shows each account's current usage window, percentage used and next reset. Account details show remaining usage and a second window when provided. Lifetime token totals and reset credits appear only when the account API returns them. Usage-window percentages are never converted into an invented token balance. Missing data is shown explicitly; reset credits are displayed but cannot be redeemed here.

Usage refreshes every five minutes and when opening stale data. Use the gear to rename accounts or change LLM Usage's appearance without changing macOS.

## Switch accounts across devices

Open an account and choose **Use this account**. **Your devices** shows which devices have confirmed that selection. Add a Linux VPS using an existing SSH alias or `user@hostname`; LLM Usage installs a private connector for that user.

Shared Codex terminals follow the selection. Already-running requests and provider connections can retain the previous account until they reconnect. Older standalone terminals and private app-server processes are outside the shared daemon. To connect explicitly:

```sh
codex --remote unix://
# Continue a saved conversation after its current standalone turn finishes:
codex --remote unix:// resume <session-id>
```

Keep LLM Usage running to renew access on remote devices. They can use the last expiring grant while the Mac is offline, but cannot refresh it themselves. Hermes needs to load its optional plugin once; installation does not restart existing gateways or sessions.

See [connector setup, compatibility and removal](CONNECTOR.md) for standalone VPS installation and Hermes details.

## Account privacy

Each account has an isolated Codex profile under `~/Library/Application Support/OpenAIQuotaBar/Sessions/<UUID>`, with sign-in credentials stored by Codex in macOS Keychain. Existing regular Codex login files are not replaced. LLM Usage obtains expiring access grants for connected devices; refresh credentials stay with the original sign-in. Grants travel through SSH and are stored with private file permissions on the destination.

The app uses authentication and account APIs. It does not send prompts or execute model tools. Tokens are not printed to logs or saved in account metadata. An account currently selected for devices must be switched away from before it can be disconnected.

Do not publish account files, real-account screenshots, tokens, SSH configuration or local diagnostic artifacts when reporting an issue.

## Development and verification

```sh
swift test
python3 -m unittest discover -s Tests/BridgeTests -v
./Scripts/package-app.sh
```

Native preview checks use synthetic accounts and require macOS Accessibility/Screen Recording permission:

```sh
swift build
swiftc Scripts/ax-snapshot.swift -o .build/ax-snapshot
swiftc Scripts/ax-action.swift -o .build/ax-action
python3 Scripts/visual-check.py
python3 Scripts/interaction-check.py --no-captures
```

The interaction helper targets the preview process directly for keyboard input. Preview captures go into the ignored `Artifacts/` directory. To exercise real protocol connections using disposable profiles and fake accounts, without model calls:

```sh
python3 Scripts/pool-integration-check.py
# Run using the Python environment of your own Hermes checkout:
/path/to/hermes/venv/bin/python Scripts/hermes-pool-check.py --hermes-root /path/to/hermes
```

The optional device-code handshake check obtains and immediately cancels a code. It does not open a browser or sign in:

```sh
QUOTABAR_LIVE_AUTH_TEST=1 swift test --filter CodexTests/testLiveDeviceHandshake
```

[Contributions](CONTRIBUTING.md) are welcome. Licensed under [MIT](LICENSE).

## References

- [OpenAI: App-server authentication and account APIs](https://learn.chatgpt.com/docs/app-server)
- [OpenAI: Device-code authentication and credential storage](https://learn.chatgpt.com/docs/auth)
- [Apple: NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
