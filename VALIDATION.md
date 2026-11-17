# Connection repair and read-only machine monitoring — 4.10.0

## Reproduced failures and corrections

- Finder-launched builds could not find Codex installed under `~/.local/node/bin`; npm launchers also failed because Node was absent from the GUI environment. The app and connector now use an explicit tool search path without executing shell startup scripts.
- Claude login only observed completion after a pasted code. Browser callbacks now finish automatically, fragmented authorization URLs are accumulated safely, and inherited provider overrides are removed from private login processes.
- A cancelled Claude connection could complete later and add a stale account. Attempt guards prevent late replies from changing state after cancellation or another provider is selected.
- Local Claude accounts could retain an “in use” label after the CLI changed identity. Identity confirmation is required, and a renewal cannot overwrite a different account selected in the meantime. A busy Claude settings lock is respected.
- Added an explicit connection to the existing local ChatGPT/Codex session. Credentials remain managed by Codex; removing this monitor does not log out the CLI. Account changes are detected before reading usage or handing out grants.
- First local activation can install the connector; reconnecting it reapplies pending selection. A verified shared connection is labeled **Shared Codex ready**, with separate-terminal limitations displayed independently.
- Provider names distinguish identically named accounts. Existing local-model features and reconnect affordances are retained.
- Added a separate monitoring-only machine list: bounded SSH reads of session-token aggregates, running agents and Ollama models. These hosts never enter account sharing or switching targets.
- Remote account monitoring identifies the default Claude/Codex sign-ins and explicitly saved LLM Usage profiles, with remaining quota percentages and reset dates separate from local token consumption. Provider credentials remain on their original machine; a changed identity cannot inherit another account's quota.

## Validation

- Swift: 88 tests, zero failures, 5 opt-in live tests skipped in the default suite.
- Python: 50 tests, zero failures, 1 optional environment-dependent test skipped.
- Real installed Codex 0.169.0: isolated daemon account switching, settings updates, independent read-back and preserved conversations passed.
- Loopback model transport: account A → B switched the actual next request, replayed the full conversation, and did not restart the daemon.
- Loopback model/reasoning change: in-flight request, conversation history and permissions preserved; next turn and resumed conversation used the selected model.
- Two real Claude sign-ins: A → B → A verified through Claude in disposable configuration/Keychain namespaces. Default CLI authentication and unrelated MCP entries remained unchanged. Temporary test namespaces removed.
- Installed macOS app: live Codex and Claude usage loaded, a second Claude account connected, provider navigation and persistence verified. The shared Codex connection accepted the real selected account without interrupting its active task.
- Remote-monitor fixtures cover cumulative Codex counters, repeated Claude message snapshots, cached-token accounting, stale network replies, offline-cache retention, corrupt configuration and separation from account-sharing targets.
- Two real remote Macs: unattended SSH collection and display in the installed app verified. A dedicated key is restricted to the checksum-verified collector; an arbitrary requested shell command was replaced by the statistics response on both machines. Installation sessions were closed afterward.
- Account-quota validation: real local Claude and Codex sign-ins and an additional private Claude profile returned identity and quota windows. Fixtures cover expired credentials, API-key sessions, wrong or changed identities, provider failures, missing quota windows, and secret-free output.

## Practical boundaries

Remote collection requires trusted, non-interactive SSH authentication for the selected OS user. Machine totals cover only that user's default Codex and Claude Code log directories; missing or capped logs are shown explicitly. They are not remaining subscription quotas. Live validation confirmed that partial totals and a missing Codex log directory remain visible instead of being presented as complete usage.

Separate/private Codex sessions need their own connection to the shared daemon before following its account. Claude switching applies to Claude Code's default configuration on this Mac; explicitly configured profiles or API-key sessions remain independent. No VPS deployment or remote account sharing was performed as part of machine monitoring.
