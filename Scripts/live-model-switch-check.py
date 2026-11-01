#!/usr/bin/env python3
"""Verify next-turn model changes on a real isolated Codex daemon and loopback provider."""
import argparse
import asyncio
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
from aiohttp import web

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


peer = load("model_peer", ROOT / "Sources/OpenAIQuotaBar/Resources/quotabar_peer.py")
fixture = load("pool_fixture", ROOT / "Scripts/pool-integration-check.py")


async def verify(executable):
    seen = []
    started, release = asyncio.Event(), asyncio.Event()

    async def endpoint(request):
        if request.path.endswith("/models"):
            return web.json_response({"models": [
                {"slug": name, "display_name": name, "description": "Loopback fixture",
                 "default_reasoning_level": "low", "supported_reasoning_levels": [
                     {"effort": effort, "description": effort} for effort in ("low", "high")],
                 "shell_type": "shell_command", "visibility": "list", "supported_in_api": True,
                 "priority": index, "base_instructions": "Reply fixture complete; do not use tools."}
                for index, name in enumerate(("gpt-5.6-sol", "gpt-6-astra"))]})
        if not request.path.endswith("/responses"):
            return web.json_response({})
        if request.headers.get("Upgrade", "").lower() == "websocket":
            socket = web.WebSocketResponse()
            await socket.prepare(request)
            async for message in socket:
                if message.type == web.WSMsgType.TEXT:
                    for event in await response_events(json.loads(message.data)):
                        await socket.send_json(event)
            return socket
        events = await response_events(await request.json())
        return web.Response(text="".join("data: " + json.dumps(event) + "\n\n" for event in events),
                            content_type="text/event-stream")

    async def response_events(payload):
        seen.append(payload)
        if len(seen) == 1:
            started.set()
            await release.wait()
        item = {"id": f"msg_{len(seen)}", "type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "fixture complete", "annotations": []}],
                "status": "completed"}
        response = {"id": f"resp_{len(seen)}", "object": "response", "created_at": int(time.time()),
                    "status": "completed", "output": [item],
                    "usage": {"input_tokens": 5, "output_tokens": 2, "total_tokens": 7}}
        events = [{"type": "response.created", "response": dict(response, status="in_progress", output=[])},
                  {"type": "response.output_item.done", "output_index": 0, "item": item},
                  {"type": "response.completed", "response": response}]
        return events

    app = web.Application()
    app.router.add_route("*", "/{tail:.*}", endpoint)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="live-model-", dir=ROOT / "Artifacts") as scratch:
        directory = Path(scratch)
        home = directory / "codex"
        home.mkdir()
        (home / "config.toml").write_text('cli_auth_credentials_store="file"\nmodel="gpt-5.6-sol"\nmodel_reasoning_effort="low"\n')
        env = {key: value for key, value in os.environ.items() if key not in (
            "CODEX_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CHATGPT_BASE_URL", "OPENAI_BASE_URL")}
        env.update(CODEX_HOME=str(home), RUST_LOG="off")
        socket = directory / "codex.sock"
        with (directory / "daemon.log").open("w") as error_log:
            process = await asyncio.create_subprocess_exec(executable,
                "--disable", "apps", "--disable", "plugins", "--disable", "remote_plugin",
                "-c", f'chatgpt_base_url="http://127.0.0.1:{port}"',
                "-c", f'openai_base_url="http://127.0.0.1:{port}/codex"',
                "app-server", "--listen", "unix://" + str(socket), env=env,
                stdout=asyncio.subprocess.DEVNULL, stderr=error_log)
            connector = peer.Peer(directory / "peer", executable, socket)
            observer = peer.CodexConnection(executable, socket, lambda: connector.grant)
            try:
                for _ in range(100):
                    if socket.exists():
                        break
                    if process.returncode is not None:
                        raise RuntimeError((directory / "daemon.log").read_text())
                    await asyncio.sleep(.05)
                await connector.select(fixture.grant("synthetic-account", "selected"))
                await observer.start()
                thread = await observer.request("thread/start", {"model": "gpt-5.6-sol", "cwd": str(directory),
                    "approvalPolicy": "on-request", "sandbox": "read-only"})
                thread_id = thread["thread"]["id"]
                first_turn = await observer.request("turn/start", {"threadId": thread_id,
                    "input": [{"type": "text", "text": "First fixture turn"}]})
                await asyncio.wait_for(started.wait(), 15)
                current = await peer.runtime_settings(connector.codex, {})
                result = await peer.runtime_settings(connector.codex, {"version": current["version"],
                    "changes": {"model": "gpt-6-astra", "effort": "high"}, "updateOpenSessions": True})
                assert result["sessionUpdates"] == {"updated": 1, "unchanged": 0, "failed": 0, "total": 1}, result
                assert seen[0]["model"] == "gpt-5.6-sol"
                release.set()

                async def completed(turn_id):
                    for _ in range(200):
                        value = (await observer.request("thread/read", {"threadId": thread_id, "includeTurns": True}))["thread"]
                        if (value.get("status", {}).get("type") == "idle" and value.get("turns")
                                and value["turns"][-1]["id"] == turn_id
                                and value["turns"][-1]["status"] != "inProgress"):
                            assert value["turns"][-1]["status"] == "completed", {key: value["turns"][-1].get(key) for key in ("status", "error")}
                            return value
                        await asyncio.sleep(.05)
                    raise TimeoutError("Fixture turn did not finish")

                await completed(first_turn["turn"]["id"])
                second_turn = await observer.request("turn/start", {"threadId": thread_id,
                    "input": [{"type": "text", "text": "Second fixture turn"}]})
                final = await completed(second_turn["turn"]["id"])
                assert seen[-1]["model"] == "gpt-6-astra", seen[-1]["model"]
                assert seen[-1]["reasoning"]["effort"] == "high"
                assert len(final["turns"]) == 2
                assert all(text in json.dumps(seen[-1]["input"]) for text in (
                    "First fixture turn", "Second fixture turn", "fixture complete"))
                resumed = await observer.request("thread/resume", {"threadId": thread_id})
                assert resumed["model"] == "gpt-6-astra" and resumed["reasoningEffort"] == "high"
                assert resumed["approvalPolicy"] == "on-request" and resumed["sandbox"]["type"] == "readOnly"
                print(json.dumps({"modelSwitch": "passed", "inFlightRequestPreserved": True,
                    "nextTurnModel": seen[-1]["model"], "effort": seen[-1]["reasoning"]["effort"],
                    "historyPreserved": True, "resumeConfirmed": True, "permissionsPreserved": True,
                    "realCredentialsUsed": False, "daemonRestarted": False}))
            finally:
                release.set()
                await observer.close()
                await connector.codex.close()
                if process.returncode is None:
                    process.terminate()
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(process.wait(), 5)
    await runner.cleanup()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=peer.find_codex())
    asyncio.run(asyncio.wait_for(verify(parser.parse_args().codex), 60))
