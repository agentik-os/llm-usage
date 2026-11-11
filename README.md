# LLM Usage

[![Verify](https://github.com/agentik-os/llm-usage/actions/workflows/ci.yml/badge.svg)](https://github.com/agentik-os/llm-usage/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-black.svg)](LICENSE)

Your OpenAI and Claude accounts, usage and connected devices in the macOS menu bar.

LLM Usage is a native Swift app with a monochrome interface, Liquid Glass on macOS 26+, and a vibrancy fallback on macOS 13–15. Track multiple accounts, see their reset times, and choose which account your shared Codex connection and Claude Code use.

## Features

- Browser sign-in with a short device code, plus a browser callback fallback.
- Claude subscription accounts (Pro/Max): 5-hour, weekly and per-model weekly limits, with reset times. Use this Mac’s Claude Code sign-in or add other Claude accounts.
- **Use in Claude Code** moves Claude Code on this Mac to another connected Claude account. Terminals that are already open follow within about a minute, without a restart, and new terminals start on it.
- **Claude rollover** moves Claude Code to another Claude account automatically when the one in use reaches 80, 90 or 95% of a limit. You choose which accounts it may use.
- **Use a reset** for OpenAI accounts that have Codex rate-limit reset credits, after confirmation.
- Multiple accounts together, with usage bars and reset dates in your local time zone.
- Each account’s sign-in email is shown on its page, in Settings and in the account menu; right-click an account to copy it.
- Editable account names and System, Light or Dark appearance independent of macOS.
- A **Ready for new requests** badge requires an independent account read-back, a successful OpenAI usage request and a running Codex version with the account-switch fix. Accepting a token alone never completes the switch.
- **Use this account** targets this Mac, all devices, one VPS, or a custom selection without closing conversations.
- Choose model and reasoning per device, including open shared Codex conversations; set Full access and YOLO defaults for new conversations.
- Connected Macs and Linux VPS devices, with per-device confirmations and reconnect retries over SSH.
- Optional Hermes middleware for its native Codex Responses integration.
- Optional local Hermes pool synchronization: all connected Codex accounts, with rollover when an account reaches its quota.
- Optional local Headroom integration for tool-output compression in Hermes and the built-in Codex OpenAI provider; see its separate setup and activation limits below.

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

The home screen shows each account's current usage window, percentage used and next reset. Account details show remaining usage and a second window when provided. Lifetime token totals and reset credits appear only when the account API returns them. Usage-window percentages are never converted into an invented token balance. Missing data is shown explicitly.

Usage refreshes every five minutes and when opening stale data. Use the gear to rename accounts or change LLM Usage's appearance without changing macOS.

## Add a Claude account

Choose **+ → Claude account…** (or **Connect Claude** on the welcome screen).

- **Use this Mac’s Claude Code** shows the account Claude Code is signed in with. LLM Usage reads that sign-in from the Keychain and leaves renewing it to Claude Code. If that sign-in expires, run `claude` once and refresh. The option is hidden once a connected account already shows Claude Code’s sign-in.
- **Sign in to another Claude account** runs `claude auth login` in a private configuration directory (`~/Library/Application Support/OpenAIQuotaBar/ClaudeSessions/<id>`). Approve access in your browser, copy the code Claude shows and paste it into LLM Usage. Claude Code must be installed. LLM Usage renews these sign-ins itself. The same account also works in a terminal with `CLAUDE_CONFIG_DIR=<that directory> claude`.

The home screen shows each Claude account’s most limiting window, either the 5-hour session or the weekly limit, together with its reset time. Account details also list per-model weekly limits when Claude provides them. Usage comes from the endpoint Claude Code’s `/usage` reads (`api.anthropic.com/api/oauth/usage`). Anthropic does not document this endpoint, so it may change.

Limits:

- Claude fixes a sign-in’s lifetime at about 30 days when you sign in, and renewals do not extend it. LLM Usage keeps the account connected until then and warns three days before you need to sign in again.
- Claude account switching covers Claude Code on this Mac. Connected devices, Hermes and reset credits apply to OpenAI accounts.
- Gemini is not supported yet.

## Switch the Claude Code account

Open a Claude account and choose **Use in Claude Code**, or right-click it in the account list. The account Claude Code runs on is marked **In use**.

The switch applies to every Claude Code process on this Mac that uses the default configuration, which is what plain `claude` uses:

- **Terminals that are already open** keep their conversation and move to the new account without a restart. Claude Code re-reads its sign-in about every 30 seconds, so the next request after that uses the new account. A request already in flight finishes on the previous account.
- **Terminals opened afterwards** start on the new account.

How it works: LLM Usage first asks Claude which account the chosen sign-in belongs to, and renews it if needed. Only then does it replace the sign-in in Claude Code’s Keychain item (`Claude Code-credentials`) and the `oauthAccount` record in `~/.claude.json`, which is what `/status` displays. Everything else in both places is kept, including the MCP server tokens Claude Code stores in the same Keychain item. A sign-in that Claude rejects, or that belongs to a different account than expected, is never handed to Claude Code.

After a switch, Claude Code and LLM Usage share one sign-in for that account. Claude Code keeps renewing it while you work, and LLM Usage copies each renewal back to the account’s private copy so the account stays connected when you switch away. If Claude Code was signed in to an account LLM Usage did not hold yet, that sign-in is kept as a new account before it is replaced. Signing in with `/login` in a terminal is detected on the next refresh.

Limits:

- Sessions started with their own `CLAUDE_CONFIG_DIR`, an API key, `ANTHROPIC_AUTH_TOKEN`, or another provider’s base URL do not use Claude Code’s stored sign-in and are not switched.
- Switching covers this Mac. Claude Code on connected VPS devices is not switched.
- The open-terminal behavior was verified with Claude Code 2.1.322. It relies on how Claude Code reloads its sign-in, which Anthropic does not document and may change.
- Do not run `CLAUDE_CONFIG_DIR=<private directory> claude` for the account Claude Code currently uses: two processes renewing the same sign-in from different places can sign one of them out.

## Claude rollover

Open **Settings → Claude rollover**, turn it on, pick the share used that triggers a move (80, 90 or 95%, default 95%), and switch on each account Claude Code may move to. Accounts you leave off are never used by rollover. You can also right-click an account in the list and choose **Add to rollover**. Rollover is off until you turn it on.

When the account Claude Code uses reaches the threshold, LLM Usage switches Claude Code to the chosen account with the most usage left, exactly as **Use in Claude Code** does: open terminals follow within about a minute and new terminals start on it. The account list then shows which account it left and which it moved to.

- **What counts**: the highest share used across the 5-hour limit, the weekly limit and the per-model weekly limits. An account is a valid destination only when every one of those is below the threshold, its usage was read without error in the last 15 minutes, and its sign-in has not expired. Usage is read again just before the move.
- **Which account leaves**: any account Claude Code is using, whether or not it is switched on for rollover. The switches only decide where Claude Code may go.
- **When nothing is available**: Claude Code stays where it is and the account list says so. It moves as soon as a chosen account has usage left again, for example after a reset.
- **Timing**: the account in use is read about every two minutes while LLM Usage runs, the others every five. A burst that uses several percent within two minutes can pass the threshold before the move, and a request already in flight finishes on the previous account.

The limits of **Use in Claude Code** apply here too. LLM Usage must be running for rollover to happen.

## Reset credits (OpenAI)

When OpenAI grants Codex rate-limit reset credits, the account’s details show how many are available and a **Use a reset** button. After you confirm, LLM Usage asks Codex (`account/rateLimitResetCredit/consume`) to redeem one credit, using a fresh idempotency key so a retry can’t spend a second credit. It then reloads usage and shows OpenAI’s result: reset, nothing to reset, no credit, or already used. A used credit can’t be restored.

## Switch accounts across devices

Open an account, choose **This Mac**, **All devices**, **Only <VPS>**, or toggle a custom set of devices, then choose **Use this account**. The selector initially includes all configured devices and reuses the last target set while the app is open. The targets are visible before switching. Each machine keeps its own account choice, including across app restarts. Delivery and verification run independently across devices, so a slow or offline VPS does not hold up the others. Account renewal is shared once per account within each synchronization pass to avoid competing token refreshes. Offline targets retry their latest saved choice; other machines retain theirs.

**Your devices** opens immediately with progress. **Retry this device** retries only that device; **Retry pending devices** skips connections already verified. Each check independently reads the actual daemon's token and version, and compatible servers must also complete an authenticated usage request. Failed, missing, mismatched or stale checks cannot display the ready badge. On macOS, a read-only process/socket inventory distinguishes shared Codex terminals from separate terminals. Linux terminal coverage is explicitly unknown; the shared connection can be verified without claiming every remote terminal uses it. Private app servers, other Unix users and in-flight requests remain outside the readiness guarantee.

**Reconnect Codex safely…** can activate an already-installed compatible update through Codex's managed restart command after explicit confirmation. It refuses while any loaded task is active or the activity check is incomplete. After a managed restart it reapplies the current selection through the persistent connector and reads it back. Unmanaged servers are never force-killed; failures remain visible. Idle terminals may need to resume their saved conversations. This action does not install a new Codex version or automatically interrupt work.

In **Connect a VPS**, LLM Usage lists concrete host aliases from this Mac’s `~/.ssh/config`, included config files, and system SSH configuration. Search and select one or several existing setups; already-added aliases are marked. Detection reads configuration only, without running SSH, `Match exec`, proxy commands, or network probes. The connection uses the original alias so SSH retains its existing keys, ports and jump hosts. A manual alias or `user@hostname` entry remains available. Connecting installs a private connector for that Linux user; detection alone does not install anything.

**Live-switch compatibility:** Codex 0.153.4 and 0.154.0 can retain the previous account's Responses WebSocket even between turns. OpenAI fixed this in [#44489](https://github.com/openai/codex/pull/44489). Real loopback model-request verification passed with the official, signed **0.155.0-alpha.3.10** prerelease, including a new connection, new account headers, full conversation input and removal of the old response ID. This is a prerelease, not the current stable release. LLM Usage checks the **running server version separately from the installed CLI** and shows **Reconnect required** until the fixed server is running. Updating the CLI alone does not update a running daemon. Unknown versions and failed checks remain unverified. The compatibility check recognizes that tested prerelease and stable versions starting at 0.155.0; private sessions are still outside its scope.

After selecting an account, LLM Usage opens the per-device result so a compatibility or reconnection warning cannot be hidden behind a successful account selection. Before restarting Codex, preserve pending questions and finish active work. LLM Usage never restarts the daemon as a side effect of selecting an account.

Shared Codex terminals follow the selection. Already-running requests and provider connections can retain the previous account until they reconnect. Older standalone terminals and private app-server processes are outside the shared daemon. To connect explicitly:

```sh
codex --remote unix://
# Continue a saved conversation after its current standalone turn finishes:
codex --remote unix:// resume <session-id>
```

Keep LLM Usage running to renew access on remote devices. They can use the last expiring grant while the Mac is offline, but cannot refresh it themselves. Hermes needs to load its optional plugin once; installation does not restart existing gateways or sessions.

See [connector setup, compatibility and removal](CONNECTOR.md) for standalone VPS installation and Hermes details.

For optional token optimization, see [local Headroom setup](Integrations/hermes-headroom/README.md). This uses a separate local service and native Hermes tool middleware. Account switching and compression are independent: the account badge does not prove that another Unix user's Hermes process uses that account or passes through Headroom. Existing processes must load the integration before it can affect their traffic. Production savings are not yet measured.

Use **Remove** on a connected VPS card to forget it in LLM Usage. This clears its saved account selection and stops future synchronization and token renewal. Its SSH setup, connector and running sessions remain in place; the last access grant stays valid until expiry. You can add it again from the existing SSH setups list. This Mac cannot be removed.

## Sync all accounts into local Hermes

Local pool sync is separate from the device connector's single selected account. With Hermes installed at `~/.hermes/hermes-agent`, create `~/.config/llm-usage/hermes-sync.json` with the exact local Hermes homes you want to synchronize:

```json
{
  "enabled": true,
  "homes": ["/Users/your-name/.hermes", "/Users/your-name/.hermes/profiles/your-profile"]
}
```

Each home must already have a `config.yaml`. Only the current Mac user's default home and explicitly listed profiles under `~/.hermes/profiles/` are supported. Restart LLM Usage after enabling it. Sync runs at launch, after **Refresh all accounts**, and every minute while the app is running. Failures are logged without credentials in the app's `hermes-sync` macOS log category and retried automatically.

The app obtains expiring access tokens through each account's existing Codex sign-in and requests renewal before expiry. Refresh credentials stay with the original sign-in. Hermes receives private, atomic updates to its native `openai-codex` credential pool. Matching independent Hermes logins retain their own complete token pair; other providers and unrelated accounts are preserved. Synchronization preserves quota cooldowns, including after access-token renewal.

The configured homes use Hermes's `fill_first` strategy: keep an available account until its quota is exhausted, then select the next available account. Hermes handles reset times and stops when no account is available. The optional `quotabar` single-account plugin must remain disabled in these homes, since it would override native pool selection. Existing Hermes processes can retain a cached pool: finish the current turn, then restart/resume the conversation once to load the complete pool. A continuously running model turn can also retain its initial credentials; the CLI re-resolves credentials between user turns.

Check each configured home with `HERMES_HOME=/path/to/home hermes auth list openai-codex`. The last successful sync receipt is `~/.local/state/llm-usage-hermes/status.json`; first-run backups are under that directory's `backups/`. Set `enabled` to `false` to stop synchronization. This does not log out or remove existing Hermes credentials.

## Model, reasoning and access settings

Open **Settings → Codex defaults**, select a device and click **Load settings**. The model list and supported reasoning efforts come from Codex on that device. **Full access** permits access outside the workspace; **YOLO mode** combines full access with no approval prompts. Click **Apply to <device>** to save the explicit changes. A concurrent config edit requires reloading before saving.

**Update open conversations** is enabled by default. Model and reasoning changes
also apply to loaded primary OpenAI conversations on the selected shared Codex
connection, including connected AGK terminals. An in-flight request finishes with
its existing model; subsequent turns use the new selection. The app uses native
`thread/settings/update` and reads the settings back for each conversation. It
reports confirmed and failed counts so partial updates can be retried. Specialist
subagents and other providers keep their own settings. No prompt is injected and
no conversation or daemon is restarted.

Full access and YOLO remain defaults for **new conversations**; an existing
conversation's access policy is preserved. Uncheck **Update open conversations**
to save defaults only. Private standalone terminals are outside the shared
connection; the app reports registered standalone AGK terminals that still need
reconnecting. For a personal AGK installation, configure
`AGK_CODEX_REMOTE=unix://` in its launcher, then use native Codex resume to reconnect
an existing conversation after its current work finishes. This setting does not
move accounts or credentials between users.

Project policies, managed settings and explicit session options can override
defaults. Remote settings use a short SSH control connection with the bundled
helper, so existing account connectors do not need restarting. Settings require
Codex support for `model/list`, `config/read` and `config/batchWrite`; live updates
add `thread/loaded/list`, `thread/read` and `thread/settings/update`. Preview mode
uses in-memory sample settings and never contacts Codex.

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

To verify pool persistence and native quota rollover using six synthetic accounts and an isolated Hermes home:

```sh
LLM_USAGE_HERMES_TEST_ROOT="$HOME/.hermes/hermes-agent" python3 -m unittest discover -s Tests/BridgeTests -p test_hermes_pool_sync.py -v
```

This check simulates provider quota responses; it does not consume real accounts' quotas.

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
# Requires aiohttp; uses synthetic accounts and loopback model responses:
python3 Scripts/live-switch-check.py --codex /path/to/codex
# Managed reconnect, account reapplication and saved-conversation resume;
# uses local legacy/fixed standalone release binaries and a disposable home:
python3 Scripts/reconnect-integration-check.py --legacy /path/to/legacy/bin/codex --codex /path/to/fixed/bin/codex
# Checks a change during an active turn, the next request, history and resume:
python3 Scripts/live-model-switch-check.py --codex /path/to/codex
# Run using the Python environment of your own Hermes checkout:
/path/to/hermes/venv/bin/python Scripts/hermes-pool-check.py --hermes-root /path/to/hermes
```

For a native compact-layout check, launch the packaged executable with
`--preview --five-accounts --compact`. Preview mode uses sample accounts and
does not connect or modify real accounts. Account details scroll when needed,
keeping the panel header and footer visible after a switch.

The optional device-code handshake check obtains and immediately cancels a code. It does not open a browser or sign in:

```sh
QUOTABAR_LIVE_AUTH_TEST=1 swift test --filter CodexTests/testLiveDeviceHandshake
```

[Contributions](CONTRIBUTING.md) are welcome. Licensed under [MIT](LICENSE).

## References

- [OpenAI: App-server authentication and account APIs](https://learn.chatgpt.com/docs/app-server)
- [OpenAI: Device-code authentication and credential storage](https://learn.chatgpt.com/docs/auth)
- [Apple: NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
