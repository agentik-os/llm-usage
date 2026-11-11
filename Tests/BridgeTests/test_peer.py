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
from unittest.mock import patch, AsyncMock

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


class CompatibilityTests(unittest.TestCase):
    def test_only_fixed_runtime_versions_are_accepted(self):
        for version in (None, "", "unknown", "0.153.4", "0.154.0", "0.155.0-alpha.1", "1.0.0-unverified"):
            self.assertFalse(peer.supports_live_switch(version), version)
        for version in ("0.155.0-alpha.3.10", "0.155.0", "0.156.0", "1.0.0"):
            self.assertTrue(peer.supports_live_switch(version), version)


class VerificationCodex:
    def __init__(self, version="0.155.1", matched=True, backend=True):
        self.server_info = {"userAgent": "quotabar_peer/" + version + " (Fixture; 4.3.0)"}
        self.matched, self.backend = matched, backend
        self.methods = []
    async def start(self):
        pass
    async def close(self):
        pass
    async def matches(self, value):
        return self.matched
    async def request(self, method, params):
        self.methods.append(method)
        if method == "thread/loaded/list":
            return {"data": ["working", "idle"]}
        if method == "thread/read":
            return {"thread": {"source": "cli", "status": {"type": "active" if params["threadId"] == "working" else "idle"}}}
        if method == "account/rateLimits/read":
            if not self.backend:
                raise RuntimeError("secret must not leak")
            return {}
        raise AssertionError(method)


class SwitchVerificationTests(unittest.IsolatedAsyncioTestCase):
    async def check(self, codex):
        with patch.object(peer, "compatibility_command", AsyncMock(return_value={"installedVersion": "0.155.1"})), \
             patch.object(peer, "terminal_coverage", return_value={"coverageKnown": True, "sharedTerminals": 5, "otherTerminals": 0}):
            return await peer.switch_verification(codex, grant(), "fixture", Path("fixture.sock"))

    async def test_readback_uses_running_server_and_never_equates_token_with_ready(self):
        old = await self.check(VerificationCodex("0.153.4"))
        self.assertTrue(old["credentialConfirmed"])
        self.assertFalse(old["liveSwitchSupported"])
        self.assertTrue(old["restartRequired"])
        self.assertFalse(old["backendVerified"])
        modern = await self.check(VerificationCodex())
        self.assertTrue(modern["backendVerified"])
        self.assertEqual(modern["activeRequests"], 1)
        self.assertEqual(modern["sharedTerminals"], 5)
        self.assertNotIn("accessToken", modern)
        remote = VerificationCodex("0.150.1")
        remote.server_info = {"userAgent": "Codex Desktop/0.150.1 (Ubuntu 26.4.0)"}
        self.assertEqual((await self.check(remote))["runningVersion"], "0.150.1")

    async def test_auth_failure_and_concurrent_switch_cannot_be_confirmed(self):
        rejected = await self.check(VerificationCodex(backend=False))
        self.assertFalse(rejected["backendVerified"])
        self.assertNotIn("secret", json.dumps(rejected))
        codex = VerificationCodex()
        codex.matches = AsyncMock(side_effect=[True, False])
        changed = await self.check(codex)
        self.assertFalse(changed["backendVerified"])
        self.assertFalse((await self.check(VerificationCodex(matched=False)))["credentialConfirmed"])

    async def test_reconnect_never_stops_active_or_unknown_work(self):
        with tempfile.TemporaryDirectory() as directory:
            args = types.SimpleNamespace(state=Path(directory), codex="fixture", codex_socket=Path("fixture.sock"))
            selected = grant()
            peer.atomic_json(args.state / "active.json", selected)
            for active in (1, None):
                result = {"liveSwitchSupported": False, "restartRequired": True, "activeRequests": active}
                with patch.object(peer, "CodexConnection", return_value=VerificationCodex()), \
                     patch.object(peer, "switch_verification", AsyncMock(return_value=result)), \
                     patch.object(peer.asyncio, "create_subprocess_exec", AsyncMock()) as spawn:
                    with self.assertRaisesRegex(peer.RuntimeSettingsError, "still working"):
                        await peer.verification_command(args, selected, reconnect=True)
                    spawn.assert_not_called()

    async def test_selection_changed_before_reconnect_does_not_touch_server(self):
        with tempfile.TemporaryDirectory() as directory:
            args = types.SimpleNamespace(state=Path(directory), codex="fixture", codex_socket=Path("fixture.sock"))
            peer.atomic_json(args.state / "active.json", grant("B", "2"))
            with patch.object(peer, "CodexConnection") as connection:
                with self.assertRaisesRegex(peer.RuntimeSettingsError, "selection changed"):
                    await peer.verification_command(args, grant(), reconnect=True)
                connection.assert_not_called()

    async def test_managed_reconnect_reapplies_selection_and_reads_back(self):
        with tempfile.TemporaryDirectory() as directory:
            args = types.SimpleNamespace(state=Path(directory), codex="fixture", codex_socket=Path("fixture.sock"))
            selected = grant()
            peer.atomic_json(args.state / "active.json", selected)
            before = {"liveSwitchSupported": False, "restartRequired": True, "activeRequests": 0}
            after = {"liveSwitchSupported": True, "credentialConfirmed": True, "backendVerified": True}
            process = types.SimpleNamespace(returncode=0, wait=AsyncMock())
            with patch.object(peer, "CodexConnection", return_value=VerificationCodex()), \
                 patch.object(peer, "switch_verification", AsyncMock(side_effect=[before, after])) as verify, \
                 patch.object(peer.asyncio, "create_subprocess_exec", AsyncMock(return_value=process)) as spawn, \
                 patch.object(peer, "rpc", AsyncMock(return_value={"ok": True})) as apply:
                self.assertEqual(await peer.verification_command(args, selected, reconnect=True), after)
                self.assertEqual(verify.await_count, 2)
                self.assertEqual(spawn.call_args.args, ("fixture", "app-server", "daemon", "restart"))
                self.assertEqual(apply.call_args.args[1]["grant"]["selectionID"], selected["selectionID"])

    def test_terminal_inventory_compares_socket_peers_and_preserves_unknown(self):
        ps = f"{os.getuid()} 10 ttys001 /bin/codex\n{os.getuid()} 11 ttys002 codex\n{os.getuid()} 12 ?? /bin/codex\n"
        sockets = "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n" \
                  "codex 12 user 10u unix 0xabc 0t0 /fixture/socket\n" \
                  "codex 10 user 39u unix 0xdef 0t0 ->0xabc\n" \
                  "codex 11 user 39u unix 0x123 0t0 ->0x456\n"
        with patch.object(peer.sys, "platform", "darwin"), patch.object(peer, "standalone_agk_count", return_value=0), \
             patch.object(peer.subprocess, "run", side_effect=[types.SimpleNamespace(stdout=ps), types.SimpleNamespace(stdout=sockets)]):
            result = peer.terminal_coverage(Path("/fixture/socket"))
        self.assertTrue(result["coverageKnown"])
        self.assertEqual(result["sharedTerminals"], 1)
        self.assertEqual(result["otherTerminals"], 1)
        with patch.object(peer.sys, "platform", "linux"), patch.object(peer, "standalone_agk_count", return_value=0):
            self.assertFalse(peer.terminal_coverage(Path("/fixture/socket"))["coverageKnown"])


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



class FakeRuntime:
    def __init__(self):
        self.config = {"model": "fixture", "model_reasoning_effort": "medium", "sandbox_mode": "workspace-write", "approval_policy": "on-request"}
        self.version = "one"
        self.writes = []
        self.methods = []
    async def start(self):
        pass
    async def request(self, method, params):
        self.methods.append(method)
        if method == "config/read":
            return {"config": dict(self.config), "layers": [{"name": {"type": "user", "file": "/fixture/config.toml"}, "version": self.version}]}
        if method == "model/list":
            return {"data": [{"id": "fixture", "model": "fixture", "displayName": "Fixture", "isDefault": True,
                "defaultReasoningEffort": "medium", "supportedReasoningEfforts": [{"reasoningEffort": e, "description": e} for e in ["medium", "high"]]}]}
        if method == "config/batchWrite":
            self.writes.append(params)
            for edit in params["edits"]:
                self.config[edit["keyPath"]] = edit["value"]
            self.version = "two"
            return {}
        raise AssertionError("Unexpected method: " + method)


class RuntimeTests(unittest.IsolatedAsyncioTestCase):
    async def test_open_conversations_confirm_model_without_interrupting_or_changing_access(self):
        class LiveRuntime(FakeRuntime):
            def __init__(self):
                super().__init__()
                self.threads = {
                    name: {"id": name, "modelProvider": "openai", "source": "cli",
                           "model": "fixture", "reasoningEffort": "medium", "status": {"type": "active"}}
                    for name in ("active", "same", "failed", "specialist", "foreign")
                }
                self.threads["same"]["reasoningEffort"] = "high"
                self.threads["specialist"]["source"] = {"subAgent": {"thread_spawn": {}}}
                self.threads["foreign"]["modelProvider"] = "another-provider"
                self.updates = []
            async def request(self, method, params):
                if method == "thread/loaded/list":
                    return {"data": list(self.threads)[:2], "nextCursor": "next"} if not params.get("cursor") else {"data": list(self.threads)[2:]}
                if method == "thread/read":
                    self.assert_no_history = params["includeTurns"] is False
                    return {"thread": dict(self.threads[params["threadId"]])}
                if method == "thread/settings/update":
                    self.updates.append(params)
                    if params["threadId"] == "failed":
                        return {}  # Acknowledgement without a matching readback is not success.
                    self.threads[params["threadId"]]["model"] = params["model"]
                    self.threads[params["threadId"]]["reasoningEffort"] = params["effort"]
                    return {}
                return await super().request(method, params)

        codex = LiveRuntime()
        with patch.object(peer, "standalone_agk_count", return_value=1):
            result = await peer.runtime_settings(codex, {"version": "one",
                "changes": {"model": "fixture", "effort": "high"}, "updateOpenSessions": True})
        self.assertEqual(result["sessionUpdates"], {"updated": 1, "unchanged": 1, "failed": 1, "total": 3})
        self.assertEqual(result["standaloneAgkSessions"], 1)
        self.assertEqual(codex.updates, [
            {"threadId": "active", "model": "fixture", "effort": "high"},
            {"threadId": "failed", "model": "fixture", "effort": "high"}])
        self.assertTrue(codex.assert_no_history)
        self.assertEqual(codex.config["sandbox_mode"], "workspace-write")
        self.assertEqual(codex.config["approval_policy"], "on-request")
        self.assertFalse(codex.writes[0]["reloadUserConfig"])

    async def test_unavailable_open_session_inventory_fails_before_saving_defaults(self):
        class UnavailableRuntime(FakeRuntime):
            async def request(self, method, params):
                if method == "thread/loaded/list":
                    raise RuntimeError("Unavailable")
                return await super().request(method, params)
        codex = UnavailableRuntime()
        with self.assertRaises(RuntimeError):
            await peer.runtime_settings(codex, {"version": "one", "changes": {"effort": "high"}, "updateOpenSessions": True})
        self.assertEqual(codex.writes, [])

    async def test_settings_change_only_requested_defaults_without_reloading_threads(self):
        codex = FakeRuntime()
        await peer.runtime_settings(codex, {"version": "one", "changes": {"effort": "high"}})
        self.assertEqual(codex.config["model_reasoning_effort"], "high")
        self.assertEqual(codex.config["sandbox_mode"], "workspace-write")
        self.assertEqual(codex.writes, [{"expectedVersion": "one", "reloadUserConfig": False,
            "edits": [{"keyPath": "model_reasoning_effort", "value": "high", "mergeStrategy": "replace"}]}])
        self.assertEqual(set(codex.methods), {"config/read", "config/batchWrite", "model/list"})

    async def test_full_access_and_yolo_are_explicit_defaults(self):
        codex = FakeRuntime()
        result = await peer.runtime_settings(codex, {"version": "one", "changes": {"sandbox": "danger-full-access", "approval": "never"}})
        self.assertEqual(result["sandbox"], "danger-full-access")
        self.assertEqual(result["approval"], "never")
        self.assertFalse(codex.writes[0]["reloadUserConfig"])

    async def test_stale_or_invalid_changes_never_write(self):
        for request in [{"version": "stale", "changes": {"effort": "high"}},
                        {"version": "one", "changes": {"effort": "imaginary"}},
                        {"version": "one", "changes": {"model": "unknown", "effort": "high"}},
                        {"version": "one", "changes": {"sandbox": "invalid"}},
                        {"version": "one", "changes": {"approval": "invalid"}},
                        {"version": "one", "changes": {"api_key": "secret"}}]:
            codex = FakeRuntime()
            with self.assertRaises(ValueError):
                await peer.runtime_settings(codex, request)
            self.assertFalse(codex.writes)

    async def test_read_does_not_write_or_expose_unrelated_configuration(self):
        codex = FakeRuntime()
        codex.config["api_key"] = "secret"
        result = await peer.runtime_settings(codex, {})
        self.assertFalse(codex.writes)
        self.assertNotIn("secret", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
