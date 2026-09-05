#!/usr/bin/env python3
"""Opt-in local check of saved QuotaBar routing grants; never print credentials.

Only QuotaBar's isolated sign-in profiles are opened. No tokens are refreshed,
no model calls are made, and no grants are sent to another device.
"""
import argparse
import asyncio
import base64
import json
import os
from pathlib import Path
import shutil
import time
import uuid


async def check_account(codex, data_dir, session_id, timeout):
    # Stored session IDs must not escape the local QuotaBar Sessions directory.
    session = str(uuid.UUID(session_id))
    if session.lower() != session_id.lower():
        raise ValueError("Invalid sign-in profile")
    profile = data_dir / "Sessions" / session_id
    if not profile.is_dir() or not profile.resolve().is_relative_to((data_dir / "Sessions").resolve()):
        raise ValueError("Saved sign-in profile not found")
    env = {k: v for k, v in os.environ.items() if k not in (
        "CODEX_HOME", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN",
        "CHATGPT_BASE_URL", "OPENAI_BASE_URL")}
    env["CODEX_HOME"] = str(profile)
    env["RUST_LOG"] = "off"
    process = await asyncio.create_subprocess_exec(
        codex, "-c", 'cli_auth_credentials_store="keyring"', "app-server", "--listen", "stdio://",
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL, env=env)

    async def call(identifier, method, params):
        process.stdin.write((json.dumps({"id": identifier, "method": method, "params": params}) + "\n").encode())
        await process.stdin.drain()
        while True:
            line = await process.stdout.readline()
            if not line:
                raise RuntimeError("Account connection closed")
            message = json.loads(line)
            if message.get("id") == identifier and "method" not in message:
                if "error" in message:
                    raise RuntimeError("Routing token request was rejected")
                return message["result"]

    try:
        await asyncio.wait_for(call(1, "initialize", {"clientInfo": {"name": "quotabar_source_check", "version": "4.0.0"}}), timeout)
        process.stdin.write(b'{"method":"initialized"}\n')
        await process.stdin.drain()
        value = await asyncio.wait_for(call(2, "getAuthStatus", {"includeToken": True, "refreshToken": False}), timeout)
        part = value["authToken"].split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
        if not claims["https://api.openai.com/auth"]["chatgpt_account_id"] or claims["exp"] <= time.time() + 30:
            raise ValueError("Routing grant is unavailable or expired")
    finally:
        if process.returncode is None:
            process.terminate()
        try:
            await asyncio.wait_for(process.wait(), 5)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()


async def verify(args):
    data_dir = args.data_dir.expanduser().resolve()
    codex = args.codex or shutil.which("codex")
    if not codex:
        candidate = Path.home() / ".local/bin/codex"
        if candidate.is_file():
            codex = str(candidate)
    if not codex:
        raise RuntimeError("Codex CLI not found")
    accounts = json.loads((data_dir / "accounts.json").read_text())
    connected = [account for account in accounts if account.get("authSessionID")]
    if not connected:
        raise RuntimeError("No connected sign-in profiles")
    for account in connected:
        await check_account(codex, data_dir, account["authSessionID"], args.timeout)
    print(json.dumps({"connectedAccounts": len(connected), "validRoutingGrants": len(connected), "credentialValuesPrinted": False}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Read grants from locally saved QuotaBar sign-in profiles")
    parser.add_argument("--data-dir", type=Path, default=Path.home() / "Library/Application Support/OpenAIQuotaBar",
                        help="Local QuotaBar data directory")
    parser.add_argument("--codex", help="Codex executable; otherwise discover on PATH")
    parser.add_argument("--timeout", type=float, default=15, help="Maximum seconds per app-server request (default: 15)")
    args = parser.parse_args()
    if args.timeout <= 0 or args.timeout > 120:
        parser.error("--timeout must be greater than zero and at most 120 seconds")
    if not args.live:
        print(json.dumps({"skipped": True, "reason": "Pass --live to check locally saved sign-in profiles."}))
        return
    try:
        asyncio.run(verify(args))
    except Exception:
        # Exception messages/tracebacks may contain provider payloads or paths.
        print(json.dumps({"ok": False, "error": "Local routing-grant check failed; verify the Codex executable and QuotaBar sign-in profiles.",
                          "credentialValuesPrinted": False}))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
