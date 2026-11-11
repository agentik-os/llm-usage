# LLM Usage connected devices

Open an account and choose **Use this account**. Check the visible target selector: it initially includes all configured devices and retains your last scope while the app is open. The shared Codex daemon changes its account without terminating conversations. Each device is delivered and verified independently; offline targets retain their latest pending selection and do not block other devices. Use **Retry this device** or **Retry pending devices** to retry without changing the target accounts.

Reliable WebSocket account switching requires the upstream fix in OpenAI Codex #44489. LLM Usage reads the actual server version and account separately from the connector's cached status. A ready result also requires an authenticated usage read and fresh matching selection. Versions 0.153.4 and 0.154.0 retain stale account connections; 0.155.0-alpha.3.10 and stable 0.155.1 passed the real loopback request test. Updating the CLI alone does not update a running daemon. The macOS terminal inventory checks Unix socket peers without reading terminal contents, process environments or tokens. Linux terminal coverage is reported as unknown. Private app-server processes and other Unix users are not controlled by the shared daemon.

**Reconnect Codex safely…** explicitly confirms before calling Codex's managed restart command. It refuses if any task is active or the inventory cannot be read, reapplies the saved account through the persistent connector, and performs a fresh check afterward. It never force-kills unmanaged servers or installs an update. A failed restart stays visible. Idle terminals may need to resume saved conversations; in-flight work is not interrupted by account selection.

New Codex terminals normally attach to the existing default shared daemon. To connect explicitly, run `codex --remote unix://`. For an older standalone terminal, let its current turn finish, then use `codex --remote unix:// resume <session-id>` to continue the saved conversation on the shared connection. LLM Usage cannot move a private running process into the daemon.

**Devices** is available from the home screen, account screen, Settings and the menu. Add a VPS by entering an existing SSH alias or `user@hostname`. LLM Usage installs the connector under that Linux user and retries the latest selection after a temporary disconnection. Each SSH user is isolated; connecting one user does not configure other users on the same host.

## Standalone VPS installer

Model settings use the same selected device's shared Codex connection. In
**Settings → Codex defaults**, **Update open conversations** updates model and
reasoning for the next turn of loaded primary OpenAI conversations. It preserves
current requests and permissions, and reports confirmation failures. Standalone
terminals must reconnect; personal AGK can opt in with `AGK_CODEX_REMOTE=unix://`.
This does not reconfigure another Unix user, provider or specialist agent.

Requires Python 3.9+, a current Codex CLI with `app-server proxy`, and a working systemd user session. Run the installer as the intended user, without sudo:

```sh
sh install.sh
```

The `LLM-Usage-Connector.zip` package includes `quotabar-peer.py`, `install.sh`, `LICENSE` and this file. Transfer that folder to a VPS, run the installer, then add its SSH alias in LLM Usage. No account credentials are included in the installer.

LLM Usage keeps the legacy `quotabar` connector filenames, paths, service names and Hermes plugin identifier for compatibility with existing installations.

The Linux service is `quotabar-peer.service`; on macOS the LaunchAgent is `com.quotabar.peer`. Code installs in `~/.local/share/quotabar/`. The private Unix control socket and current expiring access grant are in `~/.local/state/quotabar/` (directory 0700, grant and socket 0600). There is no TCP listening port, public endpoint or additional VPS password. SSH retains its normal host-key verification.

LLM Usage obtains short-lived access tokens from its own isolated Codex sign-ins. Refresh tokens stay with the original sign-in. Keep LLM Usage running on the Mac to renew grants on connected devices. A VPS can keep using the last grant while the Mac is offline, until the displayed expiry; it cannot independently refresh it. Existing `~/.codex/auth.json` files and credential stores are not replaced. Restarting a Codex daemon restores its ordinary saved login until the connector reconnects and reapplies the selection.

## Hermes

For **all accounts with automatic quota rollover on this Mac**, use [local Hermes pool synchronization](README.md#sync-all-accounts-into-local-hermes). It writes only explicitly configured local profiles and uses Hermes's native `fill_first` pool strategy. Keep the `quotabar` plugin described below disabled in those profiles: it pins requests to one selected account and would override pool rotation.

Choose **Connect Hermes** on a device card. The installer adds a user plugin under `~/.hermes/plugins/quotabar` and enables it with Hermes's own CLI. The plugin only routes provider `openai-codex` with API mode `codex_responses` to the official HTTPS ChatGPT endpoint. Models, tools and conversation content remain unchanged. Each request reads the latest selected account, including when reusing an SDK client.

Already-running Hermes processes must load the plugin once. Installing a plugin cannot inject it into their memory; let existing work finish, then restart/resume that Hermes process, or use a runtime-specific plugin reload if one is available. The installer does not restart gateways or terminals. This connector is scoped to the root Hermes profile of the SSH user; custom Hermes homes and the separate `codex_app_server` runtime need their own integration.

Token compression is a separate optional integration. See [Headroom setup and removal](Integrations/hermes-headroom/README.md) for the local sidecar, native tool middleware, Codex routing and activation limits. Installing Headroom does not change which account another Hermes home uses.

## Stop sharing or uninstall

The connector never revokes accounts. To return a shared Codex daemon to independently managed authentication, stop the connector and sign in normally with `codex login` before the last shared grant expires. Existing private sign-ins remain stored.

On Linux: `systemctl --user disable --now quotabar-peer.service`. On macOS: `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.quotabar.peer.plist`. Disable the optional Hermes plugin with `hermes plugins disable quotabar` and restart/resume Hermes when its current work is finished. Remove that device's saved entry from `~/Library/Application Support/OpenAIQuotaBar/pool.json` while LLM Usage is closed to stop future SSH synchronization.

## Verification

`Scripts/pool-integration-check.py` exercises two account selections on a real, disposable Codex daemon, checks the account from a second persistent client, and verifies the same conversation remains available. It uses no real credentials or model calls. `Scripts/hermes-pool-check.py` loads the actual Hermes middleware and checks account headers on SDK requests through an offline HTTP transport. Unit tests cover selection failure, reconnect, expiration, permissions, credential redaction and provider isolation.
