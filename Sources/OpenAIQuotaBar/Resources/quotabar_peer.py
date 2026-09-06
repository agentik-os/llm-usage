#!/usr/bin/env python3
"""LLM Usage's private, user-scoped Codex connector. Stdlib only; no TCP listener.

Commands exchange JSON over stdin or an owner-only Unix socket. Credentials are
never printed, passed in process arguments, or sent anywhere except Codex and
the user's explicitly configured SSH hosts. Only expiring access tokens persist.
"""
import argparse
import asyncio
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time

VERSION = "4.1.0"
MAX_MESSAGE = 131072


def default_state():
    return Path.home() / ".local/state/quotabar"


def atomic_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".quotabar-")
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(payload, out, separators=(",", ":"))
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


def validate_grant(value, now=None):
    now = time.time() if now is None else now
    if not isinstance(value, dict):
        raise ValueError("Invalid account selection.")
    for key in ("selectionID", "accountID", "name", "accessToken", "chatgptAccountId"):
        if not isinstance(value.get(key), str) or not value[key] or len(value[key]) > 20000:
            raise ValueError("Incomplete account selection.")
    try:
        token = value["accessToken"]
        part = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
        identity = claims["https://api.openai.com/auth"]
        expiry = float(claims["exp"])
        if identity["chatgpt_account_id"] != value["chatgptAccountId"]:
            raise ValueError()
        if expiry <= now + 15:
            raise ValueError()
    except (KeyError, ValueError, TypeError, IndexError):
        raise ValueError("The account token is expired or invalid. Refresh this account.") from None
    return {key: value[key] for key in ("selectionID", "accountID", "name", "accessToken", "chatgptAccountId")} | {
        "expiresAt": expiry, "planType": str(value.get("planType") or ""), "receivedAt": now,
    }


def find_codex():
    for path in (Path.home() / ".local/bin/codex", Path.home() / ".codex/packages/standalone/current/bin/codex",
                 Path.home() / ".codex/packages/standalone/current/codex", Path("/usr/bin/codex"),
                 Path("/opt/homebrew/bin/codex"), Path(shutil.which("codex") or "/nonexistent")):
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    raise RuntimeError("Install a current Codex CLI on this device first.")


class CodexConnection:
    def __init__(self, executable, socket_path, grant_provider):
        self.executable = executable
        self.socket_path = socket_path
        self.grant_provider = grant_provider
        self.process = None
        self.reader_task = None
        self.pending = {}
        self.sequence = 0

    @property
    def connected(self):
        return (self.process is not None and self.process.returncode is None
                and (self.reader_task is None or not self.reader_task.done()))

    async def start(self):
        if self.connected:
            return
        await self.close()
        env = dict(os.environ)
        for key in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_HOME", "OPENAI_BASE_URL", "CHATGPT_BASE_URL"):
            env.pop(key, None)
        env["RUST_LOG"] = "off"
        default_socket = Path.home() / ".codex/app-server-control/app-server-control.sock"
        if self.socket_path == default_socket and not self.socket_path.exists():
            starter = await asyncio.create_subprocess_exec(self.executable, "app-server", "daemon", "start",
                env=env, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            try:
                await asyncio.wait_for(starter.wait(), 12)
            except asyncio.TimeoutError:
                starter.terminate()
                await starter.wait()
                raise RuntimeError("Open Codex on this device, then retry.") from None
        self.process = await asyncio.create_subprocess_exec(
            self.executable, "app-server", "proxy", "--sock", str(self.socket_path),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, env=env, limit=MAX_MESSAGE * 8)
        # `app-server proxy` is a byte tunnel to the daemon's WebSocket socket,
        # not the newline protocol used by a private stdio app-server.
        key = base64.b64encode(os.urandom(16)).decode()
        upgrade = ("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + "\r\n\r\n")
        self.process.stdin.write(upgrade.encode())
        await self.process.stdin.drain()
        header = await asyncio.wait_for(self.process.stdout.readuntil(b"\r\n\r\n"), 8)
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        lines = header.split(b"\r\n")
        headers = {line.split(b":", 1)[0].lower(): line.split(b":", 1)[1].strip() for line in lines[1:] if b":" in line}
        if b" 101 " not in lines[0] or headers.get(b"sec-websocket-accept") != expected:
            raise RuntimeError("Codex does not support this control connection.")
        self.reader_task = asyncio.create_task(self.read())
        await self.request("initialize", {
            "clientInfo": {"name": "quotabar_peer", "title": "LLM Usage", "version": VERSION},
            "capabilities": {"experimentalApi": True},
        })
        await self.send({"method": "initialized"})

    async def send(self, message):
        if not self.connected:
            raise RuntimeError("Codex is not connected.")
        await self.frame(1, json.dumps(message, separators=(",", ":")).encode())

    async def frame(self, opcode, payload):
        length = len(payload)
        prefix = bytes([0x80 | opcode])
        if length < 126:
            prefix += bytes([0x80 | length])
        elif length <= 65535:
            prefix += bytes([0x80 | 126]) + struct.pack("!H", length)
        else:
            prefix += bytes([0x80 | 127]) + struct.pack("!Q", length)
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.process.stdin.write(prefix + mask + masked)
        await self.process.stdin.drain()

    async def message(self):
        chunks = bytearray()
        while True:
            first, second = await self.process.stdout.readexactly(2)
            length = second & 127
            if length == 126:
                length = struct.unpack("!H", await self.process.stdout.readexactly(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", await self.process.stdout.readexactly(8))[0]
            if length > MAX_MESSAGE * 8 or first & 0x70 or second & 0x80:
                raise ValueError("Invalid Codex frame.")
            payload = await self.process.stdout.readexactly(length)
            opcode = first & 15
            if opcode == 8:
                raise EOFError()
            if opcode == 9:
                await self.frame(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode not in (0, 1):
                raise ValueError("Invalid Codex message.")
            chunks.extend(payload)
            if len(chunks) > MAX_MESSAGE * 8:
                raise ValueError("Codex message too large.")
            if first & 0x80:
                return json.loads(chunks)

    async def request(self, method, params=None):
        self.sequence += 1
        request_id = self.sequence
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        try:
            await self.send({"id": request_id, "method": method, "params": params or {}})
            return await asyncio.wait_for(future, 20)
        finally:
            self.pending.pop(request_id, None)

    async def read(self):
        try:
            while True:
                message = await self.message()
                if "method" in message:
                    if "id" not in message:
                        continue
                    grant = self.grant_provider()
                    previous = (message.get("params") or {}).get("previousAccountId")
                    if (message["method"] == "account/chatgptAuthTokens/refresh" and grant
                            and grant["expiresAt"] > time.time() + 10
                            and (not previous or previous == grant["chatgptAccountId"])):
                        await self.send({"id": message["id"], "result": {
                            "accessToken": grant["accessToken"], "chatgptAccountId": grant["chatgptAccountId"],
                            "chatgptPlanType": grant["planType"],
                        }})
                    else:
                        await self.send({"id": message["id"], "error": {
                            "code": -32601, "message": "Refresh the selected account in LLM Usage.",
                        }})
                else:
                    future = self.pending.get(message.get("id"))
                    if future and not future.done():
                        if "error" in message:
                            # Server errors can contain submitted parameters. Never echo them.
                            future.set_exception(RuntimeError("Codex did not accept the account. Check its version and workspace restrictions."))
                        else:
                            future.set_result(message.get("result", {}))
        except (OSError, ValueError, EOFError, asyncio.IncompleteReadError, asyncio.CancelledError):
            pass
        finally:
            for future in tuple(self.pending.values()):
                if not future.done():
                    future.set_exception(RuntimeError("The Codex connection closed. Your sessions were not stopped."))

    async def apply(self, grant):
        await self.start()
        await self.request("account/login/start", {"type": "chatgptAuthTokens",
            "accessToken": grant["accessToken"], "chatgptAccountId": grant["chatgptAccountId"],
            "chatgptPlanType": grant["planType"]})
        if not await self.matches(grant):
            raise RuntimeError("Codex has not confirmed this account yet.")

    async def matches(self, grant):
        result = await self.request("getAuthStatus", {"includeToken": True, "refreshToken": False})
        return result.get("authToken") == grant["accessToken"]

    async def close(self):
        if self.reader_task:
            self.reader_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.reader_task
            self.reader_task = None
        if self.process and self.process.returncode is None:
            self.process.terminate()  # only our proxy, never the user's daemon
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.process.wait(), 2)
        self.process = None


class Peer:
    def __init__(self, state, codex, codex_socket):
        self.state = state
        self.grant = None
        self.applied = None
        self.error = None
        self.lock = asyncio.Lock()
        self.last_confirmed = None
        self.codex = CodexConnection(codex, codex_socket, lambda: self.grant)
        try:
            self.grant = validate_grant(json.loads((state / "active.json").read_text()))
        except (OSError, ValueError):
            pass

    def status(self):
        expired = bool(self.grant and self.grant["expiresAt"] <= time.time() + 15)
        return {"version": VERSION, "hostname": os.uname().nodename,
            "accountID": self.applied["accountID"] if self.applied else None,
            "selectionID": self.applied["selectionID"] if self.applied else None,
            "name": self.applied["name"] if self.applied else None,
            "codexConnected": self.codex.connected,
            "expiresAt": self.grant["expiresAt"] if self.grant else None,
            "lastConfirmed": self.last_confirmed,
            "state": "expired" if expired else "attention" if self.error else "active" if self.applied and self.codex.connected else "ready",
            "error": "Open LLM Usage on your Mac to renew this account." if expired else self.error,
            "hermesInstalled": ((Path.home() / ".hermes/plugins/quotabar/plugin.yaml").exists()
                                and (self.state / "hermes-enabled.json").exists()),
        }

    async def select(self, value, background=False):
        grant = validate_grant(value)
        async with self.lock:
            if background and value is not self.grant:
                return self.status()  # a newer user selection won while waiting
            if (self.grant and self.codex.connected and self.applied
                    and all(self.grant.get(k) == grant.get(k) for k in ("selectionID", "accessToken", "name"))):
                try:
                    if await self.codex.matches(grant):
                        self.error = None
                        self.last_confirmed = time.time()
                        return self.status()
                except Exception:
                    pass
            # Publish only after Codex confirms, so Hermes and UI cannot claim a
            # selection that the shared daemon rejected.
            try:
                await self.codex.apply(grant)
                atomic_json(self.state / "active.json", grant)
                self.grant = grant
                self.applied = grant
                self.last_confirmed = time.time()
                self.error = None
            except Exception:
                self.error = "Codex did not confirm the switch. Open Codex on this device and retry."
                raise RuntimeError(self.error) from None
            return self.status()

    async def watch(self):
        while True:
            await asyncio.sleep(5)
            if self.grant and self.grant["expiresAt"] > time.time() + 15:
                with contextlib.suppress(Exception):
                    await self.select(self.grant, background=True)

    async def handle(self, reader, writer):
        try:
            raw = await asyncio.wait_for(reader.readline(), 25)
            if len(raw) > MAX_MESSAGE:
                raise ValueError("Request too large.")
            request = json.loads(raw)
            if request.get("command") == "select":
                result = await self.select(request.get("grant"))
            elif request.get("command") == "status":
                result = self.status()
            else:
                raise ValueError("Unknown connector command.")
            reply = {"ok": True, "result": result}
        except Exception:
            reply = {"ok": False, "error": "The connector could not complete this request. Check Codex and retry."}
        writer.write(json.dumps(reply).encode() + b"\n")
        with contextlib.suppress(OSError):
            await writer.drain()
        writer.close()
        with contextlib.suppress(OSError):
            await writer.wait_closed()

    async def serve(self):
        import fcntl
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.state, 0o700)
        lock_file = (self.state / "service.lock").open("a")
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lock_file.close()
            return
        socket = self.state / "control.sock"
        if socket.exists():
            try:
                reader, writer = await asyncio.open_unix_connection(str(socket))
                writer.close()
                await writer.wait_closed()
                return  # a connector is already running; never unlink its socket
            except (ConnectionRefusedError, FileNotFoundError):
                socket.unlink(missing_ok=True)
        server = await asyncio.start_unix_server(self.handle, path=str(socket), limit=MAX_MESSAGE)
        os.chmod(socket, 0o600)
        watcher = asyncio.create_task(self.watch())
        try:
            async with server:
                await server.serve_forever()
        finally:
            watcher.cancel()
            await self.codex.close()
            socket.unlink(missing_ok=True)
            lock_file.close()


async def rpc(state, request):
    reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(str(state / "control.sock")), 3)
    try:
        writer.write(json.dumps(request).encode() + b"\n")
        await writer.drain()
        return json.loads(await asyncio.wait_for(reader.readline(), 25))
    finally:
        writer.close()
        await writer.wait_closed()


# Standalone Hermes plugin: per-request headers through supported middleware.
# No edits to Hermes core, provider choice, conversations, or saved credentials.
PLUGIN = r'''"""LLM Usage account selection for native Hermes Codex Responses requests."""
import json
from pathlib import Path
from urllib.parse import urlsplit

def route_request(**context):
    if context.get("provider") != "openai-codex" or context.get("api_mode") != "codex_responses":
        return None
    origin = urlsplit(context.get("base_url") or "")
    if origin.scheme != "https" or origin.hostname != "chatgpt.com" or origin.port not in (None, 443):
        return None
    path = Path.home() / ".local/state/quotabar/active.json"
    try:
        grant = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if not grant.get("accessToken") or not grant.get("chatgptAccountId"):
        return None
    request = dict(context["request"])
    # Keep even an expired selection explicit: the provider will reject it.
    # Falling back to the agent's cached account would silently use another one.
    headers = {k: v for k, v in (request.get("extra_headers") or {}).items()
               if k.lower() not in ("authorization", "chatgpt-account-id")}
    headers["Authorization"] = "Bearer " + grant["accessToken"]
    # Match the native Hermes SDK client's _codex_cloudflare_headers spelling.
    # Hermes runs a second preflight after middleware and stringifies headers,
    # so SDK Omit sentinels would become literal duplicate account headers.
    headers["ChatGPT-Account-ID"] = grant["chatgptAccountId"]
    request["extra_headers"] = headers
    return {"request": request, "source": "quotabar", "reason": "Selected account"}

def register(ctx):
    ctx.register_middleware("llm_request", route_request)
'''


def install_hermes():
    root = Path.home() / ".hermes"
    if not root.is_dir():
        return False
    plugin = root / "plugins/quotabar"
    plugin.mkdir(parents=True, exist_ok=True, mode=0o700)
    (plugin / "__init__.py").write_text(PLUGIN)
    (plugin / "plugin.yaml").write_text('name: quotabar\nversion: "4.0.1"\ndescription: "Use the OpenAI account selected in LLM Usage for Codex Responses requests."\nauthor: LLM Usage\n')
    # Use Hermes's own configuration command; it preserves unrelated settings.
    # This plugin only routes requests and needs no built-in tool overrides.
    # Explicitly decline that CLI prompt and close stdin: an invisible prompt
    # would otherwise wait on the caller's RPC/terminal input until timeout.
    executable = shutil.which("hermes")
    if not executable:
        candidate = Path.home() / ".local/bin/hermes"
        if candidate.exists():
            executable = str(candidate)
    if not executable:
        candidate = root / "hermes-agent/venv/bin/hermes"
        if candidate.exists():
            executable = str(candidate)
    if not executable:
        return False
    env = dict(os.environ)
    env["HERMES_HOME"] = str(root)
    result = subprocess.run([executable, "plugins", "enable", "quotabar", "--no-allow-tool-override"], env=env,
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=40)
    if result.returncode == 0:
        atomic_json(default_state() / "hermes-enabled.json", {"enabled": True, "installedAt": time.time()})
    return result.returncode == 0


def install():
    state = default_state()
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    dest = Path.home() / ".local/share/quotabar/quotabar-peer.py"
    dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    source = Path(__file__).resolve()
    if source != dest.resolve():
        shutil.copyfile(source, dest)
    os.chmod(dest, 0o700)
    codex = find_codex()
    if sys.platform == "darwin":
        import plistlib
        agent = Path.home() / "Library/LaunchAgents/com.quotabar.peer.plist"
        agent.parent.mkdir(parents=True, exist_ok=True)
        payload = {"Label": "com.quotabar.peer", "ProgramArguments": [sys.executable, str(dest), "serve", "--codex", codex],
                   "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10,
                   "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"}
        agent.write_bytes(plistlib.dumps(payload))
        os.chmod(agent, 0o600)
        # bootstrap is harmless if already loaded. Don't restart a healthy peer.
        subprocess.run(["launchctl", "bootstrap", "gui/" + str(os.getuid()), str(agent)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        unit = Path.home() / ".config/systemd/user/quotabar-peer.service"
        unit.parent.mkdir(parents=True, exist_ok=True)
        # Paths come from this installation, not untrusted command input.
        quote = lambda v: '"' + str(v).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
        unit.write_text('[Unit]\nDescription=LLM Usage account connector\nAfter=default.target\n\n[Service]\n'
            + 'ExecStart=' + ' '.join(map(quote, [sys.executable, dest, "serve", "--codex", codex]))
            + '\nRestart=on-failure\nRestartSec=5\nUMask=0077\nNoNewPrivileges=true\n\n[Install]\nWantedBy=default.target\n')
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["systemctl", "--user", "enable", "--now", "quotabar-peer.service"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"version": VERSION, "installed": True}


class RuntimeSettingsError(ValueError):
    pass


async def runtime_snapshot(codex):
    response = await codex.request("config/read", {"includeLayers": True})
    config = response.get("config", {})
    layers = [layer for layer in response.get("layers") or []
              if layer.get("name", {}).get("type") == "user" and not layer.get("name", {}).get("profile")]
    layer = layers[-1] if layers else {}
    models, cursor, seen = [], None, set()
    while True:
        page = await codex.request("model/list", {"limit": 100, "cursor": cursor})
        for model in page.get("data", []):
            models.append({key: model.get(key) for key in
                ("id", "model", "displayName", "defaultReasoningEffort", "supportedReasoningEfforts", "isDefault")})
        cursor = page.get("nextCursor")
        if not cursor:
            break
        if cursor in seen or len(models) > 1000:
            raise RuntimeSettingsError("Invalid model catalog.")
        seen.add(cursor)
    return {"model": config.get("model"), "effort": config.get("model_reasoning_effort"),
            "sandbox": config.get("sandbox_mode"), "approval": config.get("approval_policy") if isinstance(config.get("approval_policy"), str) else "custom",
            "version": layer.get("version"), "models": models}


async def runtime_settings(codex, request):
    # Dedicated control connection. Never reload or mutate any loaded thread.
    await codex.start()
    snapshot = await runtime_snapshot(codex)
    changes = request.get("changes")
    if changes is None:
        return snapshot
    if not snapshot["version"] or request.get("version") != snapshot["version"]:
        raise RuntimeSettingsError("Settings changed elsewhere. Reload before saving.")
    if not isinstance(changes, dict) or not changes or set(changes) - {"model", "effort", "sandbox", "approval"}:
        raise RuntimeSettingsError("Unsupported settings.")
    model_id = changes.get("model", snapshot["model"])
    model = next((m for m in snapshot["models"] if m["model"] == model_id), None)
    if "model" in changes or "effort" in changes:
        if model is None:
            raise RuntimeSettingsError("This model is unavailable on this device.")
        if "effort" in changes and changes["effort"] not in [e["reasoningEffort"] for e in model["supportedReasoningEfforts"]]:
            raise RuntimeSettingsError("This reasoning effort is unavailable for this model.")
        if "model" in changes and "effort" not in changes:
            raise RuntimeSettingsError("Choose a reasoning effort for the new model.")
    if "sandbox" in changes and changes["sandbox"] not in ("read-only", "workspace-write", "danger-full-access"):
        raise RuntimeSettingsError("Unsupported access mode.")
    if "approval" in changes and changes["approval"] not in ("untrusted", "on-request", "never"):
        raise RuntimeSettingsError("Unsupported approval mode.")
    keys = {"model": "model", "effort": "model_reasoning_effort", "sandbox": "sandbox_mode", "approval": "approval_policy"}
    await codex.request("config/batchWrite", {"expectedVersion": snapshot["version"], "reloadUserConfig": False,
        "edits": [{"keyPath": keys[key], "value": value, "mergeStrategy": "replace"} for key, value in changes.items()]})
    result = await runtime_snapshot(codex)
    if any(result.get(key) != value for key, value in changes.items()):
        raise RuntimeSettingsError("Saved, but a managed setting or profile overrides this choice.")
    return result


async def runtime_command(args, request):
    codex = CodexConnection(args.codex or find_codex(), args.codex_socket, lambda: None)
    try:
        return await runtime_settings(codex, request)
    finally:
        await codex.close()  # Closes only our proxy, never the shared daemon.


def main():
    parser = argparse.ArgumentParser(description="Private LLM Usage account connector")
    parser.add_argument("command", choices=["serve", "rpc", "status", "install", "install-hermes", "runtime"])
    parser.add_argument("--state", type=Path, default=default_state())
    parser.add_argument("--codex")
    parser.add_argument("--codex-socket", type=Path, default=Path.home() / ".codex/app-server-control/app-server-control.sock")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.command == "serve":
            peer = Peer(args.state, args.codex or find_codex(), args.codex_socket)
            asyncio.run(peer.serve())
            return
        if args.command == "runtime":
            request = json.loads(sys.stdin.buffer.readline(MAX_MESSAGE + 1))
            result = {"ok": True, "result": asyncio.run(runtime_command(args, request))}
        elif args.command == "install":
            result = {"ok": True, "result": install()}
        elif args.command == "install-hermes":
            enabled = install_hermes()
            result = {"ok": enabled, "result": {"enabled": enabled},
                      "error": None if enabled else "Hermes was not found or could not enable the connector."}
        else:
            request = {"command": "status"} if args.command == "status" else json.loads(sys.stdin.buffer.readline(MAX_MESSAGE + 1))
            result = asyncio.run(rpc(args.state, request))
        print(json.dumps(result))
    except KeyboardInterrupt:
        pass
    except RuntimeSettingsError as error:
        print(json.dumps({"ok": False, "error": str(error)}))
    except Exception:
        print(json.dumps({"ok": False, "error": "Connector unavailable. Check the installation and Codex connection."}))
        sys.exit(1)


if __name__ == "__main__":
    main()
