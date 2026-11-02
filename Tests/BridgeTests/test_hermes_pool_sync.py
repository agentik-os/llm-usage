import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Sources/OpenAIQuotaBar/Resources/hermes_pool_sync.py"
spec = importlib.util.spec_from_file_location("hermes_pool_sync", HELPER)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


def token(account, suffix="original"):
    body = {"exp": time.time() + 86400,
            "https://api.openai.com/auth": {"chatgpt_account_id": account}}
    encoded = base64.urlsafe_b64encode(json.dumps(body).encode()).decode().rstrip("=")
    return "test." + encoded + "." + suffix


def grant(index):
    return {"accountID": str(uuid.UUID(int=index + 1)), "name": "Account " + str(index),
            "accessToken": token("identity-" + str(index)), "chatgptAccountId": "identity-" + str(index),
            "selectionID": "hermes-local", "planType": "pro"}


class SyncTests(unittest.TestCase):
    def test_matching_native_login_keeps_its_own_token_pair(self):
        source = grant(0)
        native = {"id": "native", "source": "device_code", "auth_type": "oauth",
                  "access_token": token("identity-0", "native"), "refresh_token": "native-owned",
                  "priority": 0, "last_status": "exhausted", "last_error_code": 429}
        before = copy.deepcopy(native)
        rows = sync.merge_entries([native], [source, grant(1)])
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["access_token"], before["access_token"])
        self.assertEqual(rows[0]["refresh_token"], before["refresh_token"])
        self.assertEqual(rows[0]["last_status"], "exhausted")
        self.assertNotIn("refresh_token", rows[1])
        self.assertEqual(native, before)

    def test_token_renewal_keeps_quota_cooldown_and_other_accounts(self):
        account = grant(1)
        old = sync.merge_entries([], [account])[0]
        old.update(last_status="exhausted", last_error_code=429, last_error_reset_at=time.time() + 3600)
        account["accessToken"] = token("identity-1", "renewed")
        unrelated = {"id": "unrelated", "source": "manual", "access_token": "independent", "priority": 0}
        rows = sync.merge_entries([unrelated, old], [account])
        self.assertEqual(rows[0], unrelated)
        self.assertEqual(rows[1]["last_error_reset_at"], old["last_error_reset_at"])
        self.assertEqual(rows[1]["access_token"], account["accessToken"])
        self.assertEqual(sync.merge_entries(rows, [account]), rows)

    def test_disconnect_removes_only_managed_entries(self):
        rows = sync.merge_entries([], [grant(0), grant(1)])
        remaining = sync.merge_entries(rows, [grant(1)])
        self.assertEqual([sync.identity(e) for e in remaining], ["identity-1"])

    def test_mismatched_expired_and_refresh_credentials_are_rejected(self):
        bad = grant(0)
        bad["chatgptAccountId"] = "different"
        with self.assertRaises(ValueError): sync.validate_accounts([bad])
        bad = grant(0)
        bad["refreshToken"] = "must-not-transfer"
        with self.assertRaises(ValueError): sync.validate_accounts([bad])
        with self.assertRaises(ValueError): sync.validate_accounts([grant(0), grant(0)])

    @unittest.skipUnless(os.environ.get("LLM_USAGE_HERMES_TEST_ROOT"), "requires an explicit local Hermes checkout")
    def test_real_native_sync_reopen_and_exhaustion_rotation(self):
        hermes = Path(os.environ["LLM_USAGE_HERMES_TEST_ROOT"])
        python = hermes / "venv/bin/python"
        with tempfile.TemporaryDirectory(prefix="llm-hermes-check-") as directory:
            owner = Path(directory).resolve()
            home = owner / ".hermes"
            home.mkdir()
            (home / "config.yaml").write_text("model:\n  provider: openai-codex\n  default: gpt-6-astra\ncustom_preserved: true\n")
            env = {"HOME": str(owner), "HERMES_HOME": str(home), "USER": "test-user",
                   "PATH": os.environ["PATH"], "PYTHONPATH": str(hermes)}
            payload = {"accounts": [grant(i) for i in range(6)], "homes": [str(home)]}
            first = subprocess.run([str(python), str(HELPER), "--hermes-root", str(hermes)],
                                   input=json.dumps(payload), capture_output=True, text=True, env=env)
            self.assertEqual(first.returncode, 0, first.stdout)
            self.assertEqual(json.loads(first.stdout)["accountCount"], 6)
            probe = '''
import json, time
from unittest.mock import patch
from agent.credential_pool import load_pool
pool = load_pool("openai-codex")
assert pool._strategy == "fill_first"
assert len(pool.entries()) == 6
seen = []
with patch.object(type(pool), "_codex_quota_restored_upstream", return_value=False):
    entry = pool.select()
    assert pool.select().id == entry.id
    while entry is not None:
        assert entry.id not in seen
        seen.append(entry.id)
        entry = pool.mark_exhausted_and_rotate(status_code=429,
            error_context={"type": "usage_limit_reached", "resets_at": time.time() + 3600},
            api_key_hint=entry.runtime_api_key, credential_id=entry.id)
    assert len(seen) == 6
    reopened = load_pool("openai-codex")
    assert all(e.last_status == "exhausted" for e in reopened.entries())
    assert reopened.select() is None
print(json.dumps({"rotated_accounts": len(seen), "all_exhausted_stops": True, "reopen": True}))
'''
            result = subprocess.run([str(python), "-c", probe], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["rotated_accounts"], 6)
            # A subsequent app sync must not resurrect exhausted accounts.
            second = subprocess.run([str(python), str(HELPER), "--hermes-root", str(hermes)],
                                    input=json.dumps(payload), capture_output=True, text=True, env=env)
            self.assertEqual(second.returncode, 0, second.stdout)
            rows = json.loads((home / "auth.json").read_text())["credential_pool"]["openai-codex"]
            self.assertTrue(all(row["last_status"] == "exhausted" for row in rows))
            self.assertEqual((home / "auth.json").stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
