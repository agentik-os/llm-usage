#!/usr/bin/env python3
"""Exercise a managed Codex upgrade/reconnect with isolated state and synthetic auth.

Requires aiohttp and local legacy/fixed Codex binaries. No real account is used.
The outer process scopes CODEX_HOME only to the disposable child process.
"""
import argparse
import asyncio
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


async def fixture(args):
    from aiohttp import web
    peer = load("reconnect_peer", ROOT / "Sources/OpenAIQuotaBar/Resources/quotabar_peer.py")
    helpers = load("reconnect_fixture", ROOT / "Scripts/pool-integration-check.py")
    home = Path(args.fixture_home).resolve()
    assert Path(os.environ["CODEX_HOME"]).resolve() == home
    socket = home / "app-server-control/app-server-control.sock"
    current = home / "packages/standalone/current"
    current.parent.mkdir(parents=True)
    current.symlink_to(Path(args.legacy).resolve().parents[1])

    async def endpoint(request):
        if "usage" in request.path:
            return web.json_response({"plan_type": "pro", "rate_limit": {"allowed": True,
                "limit_reached": False, "primary_window": {"used_percent": 0,
                "limit_window_seconds": 18000, "reset_after_seconds": 3600, "reset_at": 2000000000}}})
        if request.path.endswith("/models"):
            return web.json_response({"models": []})
        if request.path.endswith("/responses"):
            item = {"id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": "fixture complete", "annotations": []}]}
            response = {"id": "resp_fixture", "object": "response", "status": "completed", "output": [item]}
            events = [{"type": "response.created", "response": dict(response, status="in_progress", output=[])},
                      {"type": "response.output_item.done", "output_index": 0, "item": item},
                      {"type": "response.completed", "response": response}]
            ws = web.WebSocketResponse()
            if ws.can_prepare(request).ok:
                await ws.prepare(request)
                async for message in ws:
                    if message.type == web.WSMsgType.TEXT:
                        for event in events:
                            await ws.send_json(event)
                return ws
            return web.Response(text="".join("data: " + json.dumps(e) + "\n\n" for e in events), content_type="text/event-stream")
        return web.json_response({})

    app = web.Application()
    app.router.add_route("*", "/{tail:.*}", endpoint)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    (home / "config.toml").write_text(f'cli_auth_credentials_store="file"\nchatgpt_base_url="http://127.0.0.1:{port}"\n'
        f'openai_base_url="http://127.0.0.1:{port}/codex"\n[features]\napps=false\nplugins=false\nremote_plugin=false\n')

    async def daemon(command):
        process = await asyncio.create_subprocess_exec(args.codex, "app-server", "daemon", command,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        raw, _ = await asyncio.wait_for(process.communicate(), 15)
        assert process.returncode == 0, "Isolated daemon lifecycle failed"
        result = json.loads(raw)
        if "socketPath" in result:
            assert Path(result["socketPath"]).resolve() == socket
        return result

    connector = peer.Peer(home / "peer", args.codex, socket)
    observer = peer.CodexConnection(args.codex, socket, lambda: None)
    serving = None
    try:
        started = await daemon("start")
        assert not peer.supports_live_switch(started["appServerVersion"])
        serving = asyncio.create_task(connector.serve())
        for _ in range(100):
            if (home / "peer/control.sock").exists():
                break
            await asyncio.sleep(.02)
        selected = helpers.grant("synthetic-reconnect", "selection")
        assert (await peer.rpc(home / "peer", {"command": "select", "grant": selected}))["ok"]
        await observer.start()
        thread = (await observer.request("thread/start", {"model": "gpt-5.4", "cwd": str(home),
            "approvalPolicy": "never", "sandbox": "read-only", "baseInstructions": "Reply fixture complete. Do not use tools."}))["thread"]
        await observer.request("turn/start", {"threadId": thread["id"], "input": [{"type": "text", "text": "Save this isolated fixture conversation."}]})
        for _ in range(150):
            saved = (await observer.request("thread/read", {"threadId": thread["id"], "includeTurns": True}))["thread"]
            if saved.get("turns") and saved["turns"][-1]["status"] == "completed":
                break
            await asyncio.sleep(.05)
        else:
            raise AssertionError("Fixture model turn did not finish")
        current.unlink()
        current.symlink_to(Path(args.codex).resolve().parents[1])
        await observer.close()
        request = {key: selected[key] for key in ("accountID", "selectionID")}
        result = await peer.verification_command(types.SimpleNamespace(state=home / "peer", codex=args.codex,
            codex_socket=socket), request, reconnect=True)
        assert result["credentialConfirmed"] and result["backendVerified"] and result["liveSwitchSupported"], result
        await observer.start()
        resumed = (await observer.request("thread/resume", {"threadId": thread["id"]}))["thread"]
        assert resumed["id"] == thread["id"]
        assert "fixture complete" in json.dumps(resumed)
        assert (await peer.rpc(home / "peer", {"command": "status"}))["result"]["selectionID"] == "selection"
        print(json.dumps({"managedReconnect": "passed", "runningVersion": result["runningVersion"],
            "accountReapplied": True, "backendVerified": True, "savedConversationResumed": True,
            "realCredentialsUsed": False, "productionDaemonTouched": False}))
    finally:
        await observer.close()
        if serving:
            serving.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await serving
        await connector.codex.close()
        await daemon("stop")
        await runner.cleanup()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--legacy", required=True)
    parser.add_argument("--codex", required=True)
    parser.add_argument("--fixture-home")
    args = parser.parse_args()
    if args.fixture_home:
        asyncio.run(asyncio.wait_for(fixture(args), 60))
    else:
        with tempfile.TemporaryDirectory(prefix="llm-reconnect-", dir="/tmp") as scratch:
            env = {k: v for k, v in os.environ.items() if k not in ("CODEX_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CHATGPT_BASE_URL", "OPENAI_BASE_URL")}
            env.update(CODEX_HOME=scratch, RUST_LOG="off")
            subprocess.run([sys.executable, __file__, "--legacy", str(Path(args.legacy).resolve()),
                "--codex", str(Path(args.codex).resolve()), "--fixture-home", scratch], env=env, check=True, timeout=75)
