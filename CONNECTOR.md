# LLM Usage connected devices

Open an account and choose **Use this account**. The shared Codex daemon changes its account without terminating its conversations. Each device shows its own confirmation. Requests and provider WebSocket connections established before the switch can retain the earlier account until the connection is renewed; LLM Usage does not interrupt them. Private app-server processes and older standalone terminals are not controlled by the shared daemon.

New Codex terminals normally attach to the existing default shared daemon. To connect explicitly, run `codex --remote unix://`. For an older standalone terminal, let its current turn finish, then use `codex --remote unix:// resume <session-id>` to continue the saved conversation on the shared connection. LLM Usage cannot move a private running process into the daemon.

**Devices** is available from the home screen, account screen, Settings and the menu. Add a VPS by entering an existing SSH alias or `user@hostname`. LLM Usage installs the connector under that Linux user and retries the latest selection after a temporary disconnection. Each SSH user is isolated; connecting one user does not configure other users on the same host.

## Standalone VPS installer

Requires Python 3.9+, a current Codex CLI with `app-server proxy`, and a working systemd user session. Run the installer as the intended user, without sudo:

```sh
sh install.sh
```

The `LLM-Usage-Connector.zip` package includes `quotabar-peer.py`, `install.sh`, `LICENSE` and this file. Transfer that folder to a VPS, run the installer, then add its SSH alias in LLM Usage. No account credentials are included in the installer.

LLM Usage keeps the legacy `quotabar` connector filenames, paths, service names and Hermes plugin identifier for compatibility with existing installations.

The Linux service is `quotabar-peer.service`; on macOS the LaunchAgent is `com.quotabar.peer`. Code installs in `~/.local/share/quotabar/`. The private Unix control socket and current expiring access grant are in `~/.local/state/quotabar/` (directory 0700, grant and socket 0600). There is no TCP listening port, public endpoint or additional VPS password. SSH retains its normal host-key verification.

LLM Usage obtains short-lived access tokens from its own isolated Codex sign-ins. Refresh tokens stay with the original sign-in. Keep LLM Usage running on the Mac to renew grants on connected devices. A VPS can keep using the last grant while the Mac is offline, until the displayed expiry; it cannot independently refresh it. Existing `~/.codex/auth.json` files and credential stores are not replaced. Restarting a Codex daemon restores its ordinary saved login until the connector reconnects and reapplies the selection.

## Hermes

Choose **Connect Hermes** on a device card. The installer adds a user plugin under `~/.hermes/plugins/quotabar` and enables it with Hermes's own CLI. The plugin only routes provider `openai-codex` with API mode `codex_responses` to the official HTTPS ChatGPT endpoint. Models, tools and conversation content remain unchanged. Each request reads the latest selected account, including when reusing an SDK client.

Already-running Hermes processes must load the plugin once. Installing a plugin cannot inject it into their memory; let existing work finish, then restart/resume that Hermes process, or use a runtime-specific plugin reload if one is available. The installer does not restart gateways or terminals. This connector is scoped to the root Hermes profile of the SSH user; custom Hermes homes and the separate `codex_app_server` runtime need their own integration.

## Stop sharing or uninstall

The connector never revokes accounts. To return a shared Codex daemon to independently managed authentication, stop the connector and sign in normally with `codex login` before the last shared grant expires. Existing private sign-ins remain stored.

On Linux: `systemctl --user disable --now quotabar-peer.service`. On macOS: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.quotabar.peer.plist`. Disable the optional Hermes plugin with `hermes plugins disable quotabar` and restart/resume Hermes when its current work is finished. Remove that device's saved entry from `~/Library/Application Support/OpenAIQuotaBar/pool.json` while LLM Usage is closed to stop future SSH synchronization.

## Verification

`Scripts/pool-integration-check.py` exercises two account selections on a real, disposable Codex daemon, checks the account from a second persistent client, and verifies the same conversation remains available. It uses no real credentials or model calls. `Scripts/hermes-pool-check.py` loads the actual Hermes middleware and checks account headers on SDK requests through an offline HTTP transport. Unit tests cover selection failure, reconnect, expiration, permissions, credential redaction and provider isolation.
