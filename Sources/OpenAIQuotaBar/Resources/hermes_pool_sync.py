#!/usr/bin/env python3
"""Receive native LLM Usage access grants on stdin and sync explicit local homes.

No refresh tokens are accepted. Existing independent sign-ins remain owned by
Hermes. Each profile is updated under Hermes's own auth-store lock.
"""
import argparse
import base64
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

SOURCE = "manual:llm-usage:"
PROVIDER = "openai-codex"


def claims(token):
    if not isinstance(token, str) or len(token) > 100_000:
        raise ValueError("Invalid access grant")
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("Invalid access grant")
    data = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
    identity = (data.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id")
    if not isinstance(identity, str) or not identity:
        raise ValueError("Missing account identity")
    return identity, float(data.get("exp", 0))


def identity(entry):
    try:
        return claims(entry.get("access_token"))[0]
    except (ValueError, TypeError, KeyError):
        return None


def validate_accounts(accounts):
    if not isinstance(accounts, list) or not accounts:
        raise ValueError("No connected accounts")
    seen = set()
    for account in accounts:
        uuid.UUID(account["accountID"])
        account_identity, expires = claims(account["accessToken"])
        if account_identity != account["chatgptAccountId"] or expires <= time.time() + 30:
            raise ValueError("Unavailable or mismatched access grant")
        if account_identity in seen:
            raise ValueError("Duplicate account identity")
        seen.add(account_identity)
        if not isinstance(account.get("name"), str) or not 0 < len(account["name"]) <= 60:
            raise ValueError("Invalid account label")
        if any("refresh" in str(key).lower() for key in account):
            raise ValueError("Refresh credentials must remain with the source sign-in")
    return accounts


def merge_entries(existing, accounts):
    """Deduplicate by account identity while retaining native refresh ownership."""
    accounts = validate_accounts(accounts)
    managed = {e.get("source"): e for e in existing if str(e.get("source", "")).startswith(SOURCE)}
    native = [copy.deepcopy(e) for e in existing if not str(e.get("source", "")).startswith(SOURCE)]
    result = native[:]
    for account in accounts:
        account_identity = account["chatgptAccountId"]
        same = next((e for e in native if identity(e) == account_identity), None)
        if same is not None:
            # Preserve the complete token pair belonging to this independent
            # native login. Never combine an imported token with its refresh token.
            same["label"] = "LLM Usage · " + account["name"]
            continue
        source = SOURCE + str(uuid.UUID(account["accountID"]))
        previous = managed.get(source)
        entry = copy.deepcopy(previous) if previous else {
            "id": "llm-usage-" + str(uuid.UUID(account["accountID"])),
            "auth_type": "oauth", "source": source, "request_count": 0,
        }
        entry.update(label="LLM Usage · " + account["name"],
                     access_token=account["accessToken"],
                     base_url="https://chatgpt.com/backend-api/codex",
                     expires_at=datetime.fromtimestamp(claims(account["accessToken"])[1], timezone.utc).isoformat())
        entry.pop("refresh_token", None)
        # Keep quota cooldowns across synchronization, including when a grant
        # renews. Token renewal is not evidence that an account's quota reset.
        result.append(entry)
    # Existing native order stays stable; imported accounts follow app order.
    for priority, entry in enumerate(result):
        entry["priority"] = priority
    return result


def safe_home(value, owner_home):
    path = Path(value).expanduser()
    root = owner_home / ".hermes"
    if path.is_symlink() or path.absolute() != path.resolve():
        raise ValueError("Hermes home must be a direct local directory")
    if path != root and not (path.parent == root / "profiles"):
        raise ValueError("Only explicitly configured local Hermes profiles are supported")
    if not path.is_dir() or not (path / "config.yaml").is_file():
        raise ValueError("Hermes profile is not installed")
    for name in ["auth.json", "config.yaml"]:
        if (path / name).is_symlink():
            raise ValueError("Symlinked authentication or configuration is not supported")
    return path


def apply_home(home, accounts, hermes_root):
    sys.path.insert(0, str(hermes_root))
    os.environ["HERMES_HOME"] = str(home)
    from hermes_cli.auth import _auth_store_lock, _load_auth_store, _save_auth_store
    from utils import atomic_yaml_write
    import yaml

    with _auth_store_lock():
        store = _load_auth_store()
        pool = store.setdefault("credential_pool", {})
        merged = merge_entries(pool.get(PROVIDER, []), accounts)
        if merged != pool.get(PROVIDER):
            pool[PROVIDER] = merged
            _save_auth_store(store)
    config_path = home / "config.yaml"
    original = config_path.read_bytes()
    config = yaml.safe_load(original) or {}
    strategies = config.setdefault("credential_pool_strategies", {})
    if strategies.get(PROVIDER) != "fill_first":
        strategies[PROVIDER] = "fill_first"
        if config_path.read_bytes() != original:
            raise RuntimeError("Concurrent Hermes configuration edit; retry sync")
        atomic_yaml_write(config_path, config)
    # Read back persisted identities; counts alone cannot prove completeness.
    stored = json.loads((home / "auth.json").read_text())["credential_pool"][PROVIDER]
    identities = {identity(e) for e in stored}
    if not all(a["chatgptAccountId"] in identities for a in accounts):
        raise RuntimeError("Persisted pool is incomplete")
    return {"accountCount": len(accounts), "entryCount": len(stored), "strategy": "fill_first"}


def backup_once(homes, owner_home):
    state = owner_home / ".local/state/llm-usage-hermes"
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    if (state / "backup.json").exists():
        return state
    backup = state / "backups" / datetime.now().strftime("%Y%m%d-%H%M%S")
    backup.mkdir(parents=True, mode=0o700)
    for index, home in enumerate(homes):
        target = backup / str(index)
        target.mkdir(mode=0o700)
        for name in ["auth.json", "config.yaml"]:
            if (home / name).exists():
                shutil.copy2(home / name, target / name)
                (target / name).chmod(0o600)
    write_receipt(state / "backup.json", {"path": str(backup), "homes": [str(h) for h in homes]})
    return state


def write_receipt(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temporary.open("x", encoding="utf-8") as handle:
        os.chmod(temporary, 0o600)
        json.dump(value, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hermes-root", type=Path, required=True)
    parser.add_argument("--apply-home", type=Path)
    args = parser.parse_args()
    payload = json.loads(sys.stdin.buffer.read(1_000_001))
    accounts = validate_accounts(payload["accounts"])
    owner_home = Path.home()
    if args.apply_home:
        home = safe_home(str(args.apply_home), owner_home)
        print(json.dumps(apply_home(home, accounts, args.hermes_root)))
        return
    homes = [safe_home(value, owner_home) for value in payload["homes"]]
    if not homes or len(homes) != len(set(homes)):
        raise ValueError("Invalid Hermes profile selection")
    state = backup_once(homes, owner_home)
    # Separate processes avoid Hermes's module-level profile/config caches.
    for home in homes:
        result = subprocess.run([sys.executable, __file__, "--hermes-root", str(args.hermes_root),
                                 "--apply-home", str(home)],
                                input=json.dumps({"accounts": accounts}).encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
        if result.returncode:
            raise RuntimeError("A local Hermes profile could not be synchronized")
    receipt = {"accountCount": len(accounts), "profileCount": len(homes), "strategy": "fill_first",
               "updatedAt": datetime.now(timezone.utc).isoformat(),
               "accounts": [a["name"] for a in accounts], "homes": [str(h) for h in homes]}
    write_receipt(state / "status.json", receipt)
    print(json.dumps(receipt))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print(json.dumps({"error": "Local Hermes pool sync failed; credentials were not logged."}))
        raise SystemExit(1) from None
