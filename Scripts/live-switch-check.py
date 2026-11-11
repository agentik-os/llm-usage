"""Verify account routing across real Codex WebSocket turns using synthetic accounts.
Requires aiohttp. All model traffic goes to a loopback fixture; no real credentials.
"""

import argparse
import asyncio
import importlib.util
import json
import os
import tempfile
import time
from pathlib import Path
from aiohttp import web

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--codex", required=True)
args = parser.parse_args()
executable = str(Path(args.codex).expanduser().resolve())
s = importlib.util.spec_from_file_location(
    "peer", root / "Sources/OpenAIQuotaBar/Resources/quotabar_peer.py"
)
p = importlib.util.module_from_spec(s)
s.loader.exec_module(p)
s = importlib.util.spec_from_file_location(
    "check", root / "Scripts/pool-integration-check.py"
)
check = importlib.util.module_from_spec(s)
s.loader.exec_module(check)
seen = []


async def endpoint(req):
    account = req.headers.get("ChatGPT-Account-Id")
    print("HTTP", req.method, req.path, account, flush=True)
    if req.path.endswith("/models"):
        return web.json_response(
            {
                "models": [
                    {
                        "slug": "gpt-5.4",
                        "display_name": "Fixture",
                        "description": "Offline fixture",
                        "default_reasoning_level": "medium",
                        "supported_reasoning_levels": [
                            {"effort": "medium", "description": "Fixture"}
                        ],
                        "shell_type": "shell_command",
                        "visibility": "list",
                        "supported_in_api": True,
                        "priority": 1,
                        "base_instructions": "Reply fixture complete.",
                    }
                ]
            }
        )
    if req.path.endswith("/usage"):
        return web.json_response(
            {
                "plan_type": "pro",
                "rate_limit": {
                    "allowed": True,
                    "limit_reached": False,
                    "primary_window": {
                        "used_percent": 0,
                        "limit_window_seconds": 18000,
                        "reset_after_seconds": 3600,
                        "reset_at": int(time.time() + 3600),
                    },
                },
            }
        )
    if "responses" not in req.path:
        return web.json_response({})
    ws = web.WebSocketResponse()
    if ws.can_prepare(req).ok:
        await ws.prepare(req)
        async for msg in ws:
            if msg.type == web.WSMsgType.TEXT:
                payload = json.loads(msg.data)
                seen.append(account)
                if account == "account-B":
                    assert not payload.get(
                        "previous_response_id"
                    ), "Previous account response reused"
                    full_input = json.dumps(payload.get("input", []))
                    assert all(
                        text in full_input
                        for text in ("Fixture 0", "Fixture 1", "fixture complete")
                    ), "Conversation input was not replayed in full"
                print("MODEL_WS", account, flush=True)
                for event in events():
                    await ws.send_json(event)
        return ws
    await req.read()
    seen.append(account)
    print("MODEL_HTTP", account, flush=True)
    return web.Response(
        text="".join("data: " + json.dumps(e) + "\n\n" for e in events()),
        content_type="text/event-stream",
    )


def events():
    rid = "resp_" + str(len(seen))
    item = {
        "id": "msg_" + str(len(seen)),
        "type": "message",
        "role": "assistant",
        "content": [
            {"type": "output_text", "text": "fixture complete", "annotations": []}
        ],
        "status": "completed",
    }
    response = {
        "id": rid,
        "object": "response",
        "created_at": int(time.time()),
        "status": "completed",
        "output": [item],
        "usage": {"input_tokens": 5, "output_tokens": 2, "total_tokens": 7},
    }
    return [
        {
            "type": "response.created",
            "response": dict(response, status="in_progress", output=[]),
        },
        {"type": "response.output_item.done", "output_index": 0, "item": item},
        {"type": "response.completed", "response": response},
    ]


async def main():
    app = web.Application()
    app.router.add_route("*", "/{tail:.*}", endpoint)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="llm-switch-live-") as temp:
        d = Path(temp)
        home = d / "home"
        home.mkdir()
        (home / "config.toml").write_text('cli_auth_credentials_store="file"\n')
        env = {
            k: v
            for k, v in os.environ.items()
            if k
            not in (
                "CODEX_HOME",
                "OPENAI_API_KEY",
                "CODEX_API_KEY",
                "CODEX_ACCESS_TOKEN",
                "CHATGPT_BASE_URL",
                "OPENAI_BASE_URL",
            )
        }
        env["CODEX_HOME"] = str(home)
        env["RUST_LOG"] = "off"
        sock = d / "codex.sock"
        err = (d / "daemon.log").open("w")
        process = await asyncio.create_subprocess_exec(
            executable,
            "--disable",
            "apps",
            "--disable",
            "plugins",
            "--disable",
            "remote_plugin",
            "-c",
            f'chatgpt_base_url="http://127.0.0.1:{port}"',
            "-c",
            f'model_providers.fixture={{name="Fixture",base_url="http://127.0.0.1:{port}/codex",wire_api="responses",requires_openai_auth=true,supports_websockets=true}}',
            "-c",
            'model_provider="fixture"',
            "app-server",
            "--listen",
            "unix://" + str(sock),
            env=env,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=err,
        )
        c = p.Peer(d / "state", executable, sock)
        o = p.CodexConnection(executable, sock, lambda: c.grant)
        try:
            for _ in range(100):
                if sock.exists():
                    break
                await asyncio.sleep(0.05)
            await c.select(check.grant("account-A", "first"))
            await o.start()
            t = await o.request(
                "thread/start",
                {
                    "model": "gpt-5.4",
                    "cwd": temp,
                    "approvalPolicy": "never",
                    "sandbox": "read-only",
                    "baseInstructions": "Respond with fixture complete. Do not use tools.",
                },
            )
            tid = t["thread"]["id"]
            print("thread created", flush=True)
            for i in range(2):
                if i:
                    await c.select(check.grant("account-B", "second"))
                    print("SWITCHED", flush=True)
                await o.request(
                    "turn/start",
                    {
                        "threadId": tid,
                        "input": [{"type": "text", "text": "Fixture " + str(i)}],
                    },
                )
                for _ in range(300):
                    await asyncio.sleep(0.1)
                    t = (
                        await o.request(
                            "thread/read", {"threadId": tid, "includeTurns": True}
                        )
                    )["thread"]
                    if t.get("turns") and t["turns"][-1]["status"] != "inProgress":
                        print(
                            "TURN",
                            t["turns"][-1]["status"],
                            t["turns"][-1].get("error"),
                            flush=True,
                        )
                        assert (
                            t["turns"][-1]["status"] == "completed"
                        ), "Fixture turn failed"
                        break
                else:
                    raise TimeoutError("Fixture turn did not complete")
            assert seen[-1] == "account-B", f"Stale account reused after switch: {seen}"
            assert "account-A" in seen
            verification = await p.switch_verification(o, c.grant, executable, sock)
            assert verification["credentialConfirmed"] and verification["backendVerified"], verification
            assert verification["liveSwitchSupported"], verification
            print(
                json.dumps(
                    {
                        "accountSwitch": "passed",
                        "fullConversationPreserved": True,
                        "realCredentialsUsed": False,
                        "daemonRestarted": False,
                        "independentVerification": "passed",
                    }
                ),
                flush=True,
            )
        finally:
            await o.close()
            await c.codex.close()
            if process.returncode is None:
                process.terminate()
            await process.wait()
            err.close()
    await runner.cleanup()


asyncio.run(asyncio.wait_for(main(), 60))
