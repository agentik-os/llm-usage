import asyncio
import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import types
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[2] / "Sources/OpenAIQuotaBar/Resources/quotabar_peer.py"
spec = importlib.util.spec_from_file_location("quotabar_peer", source)
peer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(peer)


def grant(account="A", selection="1", expiry=None):
    claims = {"https://api.openai.com/auth": {"chatgpt_account_id": account}, "exp": expiry or time.time() + 3600}
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return {"accountID": account, "selectionID": selection, "name": "Account " + account,
            "accessToken": "test." + payload + ".test", "chatgptAccountId": account, "planType": "pro"}


class FakeCodex:
    connected = False
    fail = False
    calls = 0
    def __init__(self):
        self.active = None
    async def apply(self, value):
        self.calls += 1
        await asyncio.sleep(.01)
        if self.fail:
            raise RuntimeError("private token MUST NEVER APPEAR")
        self.connected = True
        self.active = value
    async def close(self):
        self.connected = False
    async def matches(self, value):
        return bool(self.connected and self.active and
                    self.active.get("accessToken") == value.get("accessToken"))


class PeerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name)
        self.connector = peer.Peer(self.state, "unused", "unused")
        self.connector.codex = FakeCodex()
    def tearDown(self):
        self.temp.cleanup()

    async def test_switch_confirms_and_keeps_only_access_grant(self):
        a, b = grant(), grant("B", "2")
        await self.connector.select(a)
        original_request = dict(self.connector.codex.active)
        result = await self.connector.select(b)
        self.assertEqual(original_request["accountID"], "A")
        self.assertEqual(result["accountID"], "B")
        self.assertEqual(result["selectionID"], "2")
        self.assertEqual(result["state"], "active")
        saved = json.loads((self.state / "active.json").read_text())
        self.assertNotIn("refresh_token", saved)
        self.assertNotIn("accessToken", result)
        self.assertNotIn(b["accessToken"], json.dumps(result))
        self.assertEqual((self.state / "active.json").stat().st_mode & 0o777, 0o600)

    async def test_rejected_switch_preserves_confirmed_choice(self):
        await self.connector.select(grant())
        self.connector.codex.fail = True
        with self.assertRaisesRegex(RuntimeError, "did not confirm"):
            await self.connector.select(grant("B", "2"))
        self.assertEqual(self.connector.status()["accountID"], "A")
        self.assertEqual(json.loads((self.state / "active.json").read_text())["accountID"], "A")
        self.assertNotIn("MUST NEVER", json.dumps(self.connector.status()))

    async def test_refresh_same_selection_avoids_repeated_logins(self):
        a = grant()
        await self.connector.select(a)
        await self.connector.select(a)
        self.assertEqual(self.connector.codex.calls, 1)
        updated = grant(expiry=time.time() + 7200)
        await self.connector.select(updated)
        self.assertEqual(self.connector.codex.calls, 2)
        self.assertEqual(self.connector.status()["selectionID"], "1")

    async def test_reconnect_reapplies_the_latest_selection(self):
        await self.connector.select(grant())
        await self.connector.select(grant("B", "2"))
        self.connector.codex.connected = False
        await self.connector.select(self.connector.grant)
        self.assertEqual(self.connector.codex.calls, 3)
        self.assertEqual(self.connector.codex.active["accountID"], "B")

    async def test_cached_selection_repairs_auth_drift(self):
        selected = grant()
        await self.connector.select(selected)
        self.connector.codex.active = grant("other", "other")
        await self.connector.select(selected)
        self.assertEqual(self.connector.codex.calls, 2)
        self.assertEqual(self.connector.codex.active["accountID"], "A")

    async def test_queued_background_refresh_cannot_restore_an_old_selection(self):
        await self.connector.select(grant())
        previous = self.connector.grant
        started, release = asyncio.Event(), asyncio.Event()
        apply = self.connector.codex.apply

        async def pause_next_apply(value):
            if value["accountID"] == "B":
                started.set()
                await release.wait()
            await apply(value)

        self.connector.codex.apply = pause_next_apply
        switch = asyncio.create_task(self.connector.select(grant("B", "2")))
        await asyncio.wait_for(started.wait(), timeout=2)
        refresh = asyncio.create_task(self.connector.select(previous, background=True))
        await asyncio.sleep(0)  # Let the stale watcher queue behind the switch lock.
        release.set()
        await asyncio.wait_for(asyncio.gather(switch, refresh), timeout=2)
        self.assertEqual(self.connector.status()["accountID"], "B")
        self.assertEqual(self.connector.codex.active["accountID"], "B")
        self.assertEqual(self.connector.codex.calls, 2)

    async def test_expiry_and_identity_validation(self):
        for invalid in (grant(expiry=time.time() - 1), dict(grant(), chatgptAccountId="other"), {}, {"accessToken": "x"}):
            with self.assertRaises(ValueError):
                await self.connector.select(invalid)
        self.assertEqual(self.connector.codex.calls, 0)

    async def test_private_socket_status_and_error_redaction(self):
        task = asyncio.create_task(self.connector.serve())
        try:
            for _ in range(100):
                if (self.state / "control.sock").exists():
                    break
                await asyncio.sleep(.01)
            result = await peer.rpc(self.state, {"command": "select", "grant": grant()})
            self.assertTrue(result["ok"])
            self.assertEqual(result["result"]["state"], "active")
            self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
            self.assertEqual((self.state / "control.sock").stat().st_mode & 0o777, 0o600)
            failed = await peer.rpc(self.state, {"command": "select", "grant": {"accessToken": "SECRET"}})
            self.assertFalse(failed["ok"])
            self.assertNotIn("SECRET", json.dumps(failed))
        finally:
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task


class HermesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.module = types.ModuleType("quotabar_plugin")
        exec(peer.PLUGIN, self.module.__dict__)
        self.request = {"input": [{"role": "user", "content": "Keep my conversation"}], "model": "sample", "stream": True}

    def tearDown(self):
        self.temp.cleanup()

    def route(self, **overrides):
        values = dict(provider="openai-codex", api_mode="codex_responses", base_url="https://chatgpt.com/backend-api/codex", request=self.request)
        values.update(overrides)
        with patch.object(Path, "home", return_value=self.home):
            return self.module.route_request(**values)

    def test_existing_conversation_uses_new_account_on_next_request(self):
        path = self.home / ".local/state/quotabar/active.json"
        peer.atomic_json(path, grant())
        first = self.route()["request"]
        peer.atomic_json(path, grant("B", "2"))
        second = self.route()["request"]
        self.assertEqual(first["extra_headers"]["ChatGPT-Account-ID"], "A")
        self.assertEqual(second["extra_headers"]["ChatGPT-Account-ID"], "B")
        self.assertIs(second["input"], self.request["input"])
        self.assertEqual(second["model"], self.request["model"])
        self.assertNotIn("extra_headers", self.request)

    def test_request_header_aliases_are_replaced_without_sdk_sentinels(self):
        peer.atomic_json(self.home / ".local/state/quotabar/active.json", grant())
        aliases = {"ChatGPT-Account-Id": "old", "chatgpt-account-id": "old",
                   "CHATGPT-ACCOUNT-ID": "old", "Chatgpt-Account-Id": "old",
                   "Authorization": "old", "authorization": "old", "AUTHORIZATION": "old",
                   "x-session-id": "same-conversation"}
        self.request["extra_headers"] = aliases
        result = self.route()["request"]["extra_headers"]
        self.assertEqual([key for key in result if key.lower() == "chatgpt-account-id"],
                         ["ChatGPT-Account-ID"])
        self.assertEqual([key for key in result if key.lower() == "authorization"],
                         ["Authorization"])
        self.assertEqual(result["x-session-id"], "same-conversation")
        self.assertTrue(all(isinstance(value, str) for value in result.values()))
        self.assertEqual(self.request["extra_headers"], aliases)

    def test_credentials_never_route_to_unrelated_providers(self):
        peer.atomic_json(self.home / ".local/state/quotabar/active.json", grant())
        for value in ("https://example.com", "https://chatgpt.com.evil.test", "http://chatgpt.com", "https://chatgpt.com:8443"):
            self.assertIsNone(self.route(base_url=value))
        self.assertIsNone(self.route(provider="anthropic"))
        self.assertIsNone(self.route(api_mode="codex_app_server"))


if __name__ == "__main__":
    unittest.main()
