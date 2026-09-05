#!/usr/bin/env python3
"""Offline Hermes discovery, both preflights, native SSE runtime, and SDK wire check.

Uses the real Hermes default-header builder and reuses one SDK client across an
account change. Only the network boundary is mocked; no saved credentials load.
"""
import argparse
import base64
from copy import deepcopy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--hermes-root", default=os.environ.get("QUOTABAR_HERMES_ROOT"),
                    help="Opt in using this Hermes checkout (or QUOTABAR_HERMES_ROOT)")
parser.add_argument("--hermes-cli", default=os.environ.get("QUOTABAR_HERMES_CLI"),
                    help="Hermes CLI executable (or QUOTABAR_HERMES_CLI); otherwise discover on PATH")
args = parser.parse_args()
if not args.hermes_root:
    print(json.dumps({"skipped": True, "reason": "Set --hermes-root or QUOTABAR_HERMES_ROOT to run the optional Hermes integration check."}))
    raise SystemExit(0)
hermes_root = Path(args.hermes_root).expanduser().resolve()
if not (hermes_root / "hermes_cli/plugins.py").is_file():
    parser.error("--hermes-root must contain a Hermes checkout with hermes_cli/plugins.py")
executable = args.hermes_cli or shutil.which("hermes")
if not executable:
    candidate = hermes_root / "venv/bin/hermes"
    if candidate.is_file():
        executable = str(candidate)
if not executable:
    parser.error("Hermes CLI not found; provide --hermes-cli or install it on PATH")
sys.path.insert(0, str(hermes_root))
spec = importlib.util.spec_from_file_location("peer", root / "Sources/OpenAIQuotaBar/Resources/quotabar_peer.py")
peer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(peer)


def token(account):
    claims = {"https://api.openai.com/auth": {"chatgpt_account_id": account}}
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "test." + payload + ".test"


with tempfile.TemporaryDirectory(prefix="quotabar-hermes-") as scratch:
    home = Path(scratch)
    hermes_home = home / ".hermes"
    plugin = hermes_home / "plugins/quotabar"
    hermes_home.mkdir()
    config = {"custom_preserved": {"nested": ["original", {"value": 2}]},
              "plugins": {"enabled": [], "disabled": ["quotabar", "unrelated-plugin"]}}
    (hermes_home / "config.yaml").write_text(json.dumps(config))
    other_profile = hermes_home / "profiles/unrelated/config.yaml"
    other_profile.parent.mkdir(parents=True)
    other_profile.write_text('model:\n  default: keep-this-profile\n')
    original_profile = other_profile.read_bytes()
    # Run the real CLI without a terminal. This used to hang invisibly at its
    # tool-override permission prompt after already writing the enabled list.
    with (patch.object(Path, "home", return_value=home),
          patch.object(peer.shutil, "which", return_value=executable)):
        assert peer.install_hermes(), "Noninteractive Hermes installer did not finish"
    import yaml
    installed = yaml.safe_load((hermes_home / "config.yaml").read_text())
    assert installed["custom_preserved"] == config["custom_preserved"]
    assert installed["plugins"]["enabled"] == ["quotabar"]
    assert installed["plugins"]["disabled"] == ["unrelated-plugin"]
    assert installed["plugins"]["entries"]["quotabar"]["allow_tool_override"] is False
    assert other_profile.read_bytes() == original_profile
    assert json.loads((home / ".local/state/quotabar/hermes-enabled.json").read_text())["enabled"]
    with (patch.dict(os.environ, {"HOME": str(home), "HERMES_HOME": str(hermes_home)}),
          patch.object(Path, "home", return_value=home),
          patch.object(socket.socket, "connect", side_effect=AssertionError("Unexpected real network request"))):
        import httpx
        from openai import OpenAI
        from agent.auxiliary_client import _codex_cloudflare_headers
        from agent.codex_runtime import run_codex_stream
        from agent.transports.codex import ResponsesApiTransport
        from hermes_cli.plugins import discover_plugins, has_middleware
        from hermes_cli.middleware import apply_llm_request_middleware

        discover_plugins()
        assert has_middleware("llm_request"), "Plugin did not load into Hermes"
        endpoint = "https://chatgpt.com/backend-api/codex"
        defaults = _codex_cloudflare_headers(token("cached-account"), base_url=endpoint)
        assert defaults["ChatGPT-Account-ID"] == "cached-account"
        seen = []

        def receive(request):
            body = json.loads(request.content)
            seen.append((request.headers, body))
            response = {"id": "test-response", "object": "response", "created_at": 0,
                        "model": "gpt-5.4", "status": "completed", "output": []}
            if body.get("stream"):
                events = [
                    {"type": "response.output_text.delta", "delta": "Still here", "output_index": 0,
                     "content_index": 0, "item_id": "message-test", "sequence_number": 0},
                    {"type": "response.completed", "response": response, "sequence_number": 1},
                ]
                data = "".join("data: " + json.dumps(event) + "\n\n" for event in events)
                return httpx.Response(200, content=data, headers={"Content-Type": "text/event-stream"})
            return httpx.Response(200, json=response)

        history = [{"role": "user", "content": "Preserve this conversation"},
                   {"role": "assistant", "content": "I will keep the same context."},
                   {"role": "user", "content": "Continue after switching."}]
        original = {
            "model": "gpt-5.4", "instructions": "The same system instructions on every request.",
            "input": history, "tools": [{"type": "function", "name": "test_tool",
                "description": "Same tool schema", "parameters": {"type": "object", "properties": {}}}],
            "extra_headers": {"ChatGPT-Account-Id": "stale", "chatgpt-account-id": "stale",
                "CHATGPT-ACCOUNT-ID": "stale", "Chatgpt-Account-Id": "stale",
                "authorization": "stale", "AUTHORIZATION": "stale", "Authorization": "stale",
                "x-session-id": "unchanged-session"},
        }
        before = deepcopy(original)
        transport = ResponsesApiTransport()
        deltas = []

        def on_delta(text):
            deltas.append(text)
            if len(deltas) == 1:
                # Change the pool while A's SSE response is being consumed.
                # That response must still complete; the next request uses B.
                peer.atomic_json(home / ".local/state/quotabar/active.json",
                                 {"accessToken": token("B"), "chatgptAccountId": "B"})

        agent = SimpleNamespace(
            _interrupt_requested=False, _current_api_request_id="offline-check", _fallback_index=0,
            is_subagent=False, model=original["model"], provider="openai-codex", session_id="",
            _is_codex_backend=lambda: True, _touch_activity=lambda *args: None,
            _fire_stream_delta=on_delta, _fire_reasoning_delta=lambda *args: None,
        )
        with OpenAI(api_key=token("cached-account"), base_url=endpoint, default_headers=defaults,
                    http_client=httpx.Client(transport=httpx.MockTransport(receive))) as client:
            for mode in ("sdk-direct", "native-stream"):
                pair = []
                for account in ("A", "B"):
                    peer.atomic_json(home / ".local/state/quotabar/active.json",
                                     {"accessToken": token(account), "chatgptAccountId": account})
                    # Exact main-loop ordering: preflight -> request middleware ->
                    # execution preflight -> native runtime -> sanitize/bypass -> SDK.
                    prepared = transport.preflight_kwargs(original, sanitize_harmony_tokens=True)
                    result = apply_llm_request_middleware(prepared, provider="openai-codex",
                        api_mode="codex_responses", base_url=endpoint)
                    assert result.changed
                    if mode == "native-stream":
                        routed = transport.preflight_kwargs(result.payload, sanitize_harmony_tokens=True)
                        response = run_codex_stream(agent, routed, client=client)
                        assert response.status == "completed" and response.output_text == "Still here"
                    else:
                        client.responses.create(**result.payload, stream=False)
                    headers, body = seen[-1]
                    assert headers.get_list("authorization") == ["Bearer " + token(account)], (mode, "duplicate or stale Authorization")
                    assert headers.get_list("chatgpt-account-id") == [account], (mode, "duplicate or stale account header", headers.get_list("chatgpt-account-id"))
                    assert headers["x-session-id"] == "unchanged-session"
                    assert "extra_headers" not in body
                    pair.append(body)
                assert pair[0] == pair[1], (mode, "Account switching altered the conversation body")
            assert original == before, "Original conversation mutated"
            assert deltas == ["Still here", "Still here"]
            assert client.api_key == token("cached-account"), "Cached client credentials mutated"
        print(json.dumps({"noninteractiveInstaller": "passed", "profilePreservation": "passed",
            "hermesPluginDiscovery": "passed", "realMiddleware": "passed",
            "sdkAuthOverride": "passed", "postMiddlewarePreflight": "passed", "nativeCodexSSE": "passed",
            "singleAuthAndAccountHeaders": "passed", "conversationPreserved": True,
            "sameClientAcrossSwitch": True, "switchDuringStream": "passed", "networkRequests": 0}))
