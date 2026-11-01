# Local Headroom integration

This optional native Hermes plugin compresses **new tool output** through a Headroom sidecar on `127.0.0.1:18787`. It runs after a tool succeeds and before its result enters conversation history. Earlier messages, provider credentials, model choice and reasoning effort are unchanged. It is separate from the `quotabar` account-selection plugin.

Use `headroom-ai[proxy]==0.37.0` with Python 3.13 in an isolated environment:

```sh
uv tool install --python 3.13 'headroom-ai[proxy]==0.37.0'
```

Run the service with the conservative settings below. These settings are part of this plugin's contract: `/v1/compress` otherwise supports transformations that discard information.

```sh
HEADROOM_SAVINGS_PROFILE=balanced \
HEADROOM_COMPRESS_USER_MESSAGES=0 \
HEADROOM_COMPRESS_SYSTEM_MESSAGES=0 \
HEADROOM_LOSSLESS=1 \
HEADROOM_LOSSLESS_THEN_LOSSY=0 \
HEADROOM_DEDUPE=0 \
HEADROOM_PROTECT_READS=1 \
HEADROOM_EFFORT_ROUTER=0 \
HEADROOM_OUTPUT_SHAPER=0 \
HEADROOM_TOOL_SEARCH=0 \
HEADROOM_TELEMETRY=off \
HEADROOM_KOMPRESS_ENABLED=0 \
headroom proxy --host 127.0.0.1 --port 18787 --mode cache \
  --lossless --no-ccr --disable-kompress --disable-kompress-fallback \
  --no-code-aware --no-read-lifecycle --no-memory-tools --no-memory-context \
  --no-learn --no-telemetry --no-subscription-tracking --no-rate-limit \
  --no-cache --stateless
```

Use launchd on macOS or a systemd user service on Linux to keep this process available. Give it its own working directory outside a source checkout. `--no-cache` disables Headroom's response cache; `--mode cache` still preserves provider prompt prefixes. Stateless mode disables Headroom's durable content storage and metrics history. Statistics at `/stats` cover the current process lifetime and include synthetic checks.

Copy this directory's `__init__.py` and `plugin.yaml` into `$HERMES_HOME/plugins/headroom-local/`, then run `hermes plugins enable headroom-local` for that Hermes home. No tool-override privilege is needed. Custom profiles and other Unix users require their own installation. Let existing tasks finish before reloading or restarting their Hermes process: editing configuration does not inject code into a running gateway.

The plugin only calls the local compression endpoint, never a model. Its `gpt-4o` field selects a token-count estimate, not an inference model. It ignores HTTP proxy environment variables and refuses redirects. It preserves terminal envelopes, exit status and session identifiers, skips known file reads and failed commands, and keeps the original result on timeout, invalid output or service failure. It never retries a tool. Results below 1,500 or above 500,000 characters pass through unchanged.

For the built-in Codex OpenAI provider, place this key at the **top level** of the user's `~/.codex/config.toml`, before any tables, once the service has passed its health and transport checks:

```toml
openai_base_url = "http://127.0.0.1:18787/v1"
```

This preserves the provider identifier and existing session history. Explicit custom providers and existing processes may retain their own routes. Unlike the Hermes middleware, Codex depends on the proxy being available; remove this key to restore direct routing before stopping Headroom. The `chatgpt_base_url` and sign-in endpoints do not need changing. Do not run an automatic history-retagging wrapper over active conversations.

Validation performed on 8 September 2026: native plugin loading on macOS and two Linux installations, one tool execution per call, unchanged terminal metadata, exact reconstruction of synthetic search output, and successful HTTP and WebSocket Responses requests through the proxy. The search fixture decreased from 6,427 to 3,235 estimated tokens. Other fixtures, including some JSON and logs, were unchanged. These are test results, not measured production savings.

```sh
python3 -m unittest discover -s Tests/BridgeTests -p test_headroom_middleware.py -v
```

To remove the Hermes integration, disable `headroom-local` in each affected Hermes home, then reload it after current work finishes. Remove the Codex routing key before disabling the Headroom service. Preserve later configuration edits when using backups.

References: [Headroom](https://github.com/headroomlabs-ai/headroom), [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
