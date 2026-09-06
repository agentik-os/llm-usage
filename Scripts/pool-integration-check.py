#!/usr/bin/env python3
"""Exercise a real Codex daemon with disposable accounts and no model calls.

The daemon, its home, its conversation, and credentials are isolated. No real
auth cache is read or written. A second persistent client observes both switches.
"""
import asyncio
import base64
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("peer", root / "Sources/OpenAIQuotaBar/Resources/quotabar_peer.py")
peer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(peer)


def grant(account, selection):
    claims = {"exp": time.time() + 3600, "https://api.openai.com/auth": {"chatgpt_account_id": account, "chatgpt_plan_type": "pro"}}
    segment = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return {"accountID": account, "selectionID": selection, "name": "Test account", "accessToken": "eyJhbGciOiJub25lIn0." + segment + ".test",
            "chatgptAccountId": account, "planType": "pro"}


async def check():
    with tempfile.TemporaryDirectory(prefix="quotabar-native-") as scratch:
        folder = Path(scratch)
        sock = folder / "codex.sock"
        executable = peer.find_codex()
        env = {k: v for k, v in os.environ.items() if k not in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_HOME", "OPENAI_BASE_URL", "CHATGPT_BASE_URL")}
        env["CODEX_HOME"] = str(folder / "codex-home")
        Path(env["CODEX_HOME"]).mkdir()
        (Path(env["CODEX_HOME"]) / "config.toml").write_text('sandbox_mode = "workspace-write"\napproval_policy = "on-request"\n')
        env["RUST_LOG"] = "off"
        process = await asyncio.create_subprocess_exec(executable, "-c", 'cli_auth_credentials_store="file"',
            "-c", 'chatgpt_base_url="http://127.0.0.1:9"', "app-server", "--listen", "unix://" + str(sock),
            env=env, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        connector = peer.Peer(folder / "peer", executable, sock)
        observer = peer.CodexConnection(executable, sock, lambda: connector.grant)
        try:
            for _ in range(200):
                if sock.exists():
                    break
                if process.returncode is not None:
                    raise RuntimeError("Isolated Codex daemon failed to start: " + (await process.stderr.read()).decode())
                await asyncio.sleep(.05)
            a, b = grant("test-account-a", "first"), grant("test-account-b", "second")
            await connector.codex.start()
            print("Isolated Codex control connection initialized", flush=True)
            await connector.codex.apply(a)
            await connector.select(a)
            await observer.start()
            first = await observer.request("getAuthStatus", {"includeToken": True, "refreshToken": False})
            assert first.get("authToken") == a["accessToken"]
            thread = await observer.request("thread/start", {"model": "gpt-5.4", "cwd": str(folder), "approvalPolicy": "never", "sandbox": "read-only"})
            thread_id = thread["thread"]["id"]
            await connector.select(b)
            second = await observer.request("getAuthStatus", {"includeToken": True, "refreshToken": False})
            assert second.get("authToken") == b["accessToken"]
            settings = await peer.runtime_settings(observer, {})
            assert settings["version"] and settings["models"]
            selected_model = settings["models"][0]
            changed = await peer.runtime_settings(observer, {"version": settings["version"], "changes": {
                "model": selected_model["model"], "effort": selected_model["defaultReasoningEffort"],
                "sandbox": "danger-full-access", "approval": "never"}})
            assert changed["model"] == selected_model["model"]
            assert changed["sandbox"] == "danger-full-access" and changed["approval"] == "never"
            try:
                await peer.runtime_settings(observer, {"version": settings["version"], "changes": {"approval": "on-request"}})
                raise AssertionError("Stale settings must be rejected")
            except ValueError:
                pass
            preserved = await observer.request("thread/read", {"threadId": thread_id, "includeTurns": False})
            assert preserved["thread"]["id"] == thread_id
            assert process.returncode is None
            print(json.dumps({"nativeAccountSwitch": "passed", "persistentObserver": "passed", "conversationPreserved": True,
                              "runtimeDefaults": "passed", "staleWriteRejected": True, "daemonRestarted": False, "realCredentialsUsed": False, "modelRequests": 0}))
        finally:
            await observer.close()
            await connector.codex.close()
            if process.returncode is None:
                process.terminate()
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(process.wait(), 5)


if __name__ == "__main__":
    asyncio.run(check())
