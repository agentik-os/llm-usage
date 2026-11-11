"""Native Hermes tool middleware; no provider/auth changes or extra LLM calls."""
import json
import re
from urllib import request

ENDPOINT = "http://127.0.0.1:18787/v1/compress"
TIMEOUT = 1.5
MIN_CHARS = 1500
MAX_CHARS = 500_000
_READ_TOOLS = {"read", "read_file", "file_read", "view", "edit", "write", "apply_patch"}
_SHELL_TOOLS = {"terminal", "bash", "exec_command", "execute_code"}
_READ_COMMAND = re.compile(r"(?:^|[\s;&|()])(?:cat|sed|head|tail|less|more|bat|awk)(?:\s|$)")


class _NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _post(payload):
    # Ignore proxy environment variables; tool output stays on this host.
    opener = request.build_opener(request.ProxyHandler({}), _NoRedirect())
    req = request.Request(
        ENDPOINT, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "X-Headroom-Client": "hermes"},
    )
    with opener.open(req, timeout=TIMEOUT) as response:
        raw = response.read(4_000_001)
    if len(raw) > 4_000_000:
        raise ValueError("Oversized compression response")
    return json.loads(raw)


def _compress_text(text, tool_name, args):
    if not isinstance(text, str) or not MIN_CHARS <= len(text) <= MAX_CHARS:
        return text
    messages = [
        {"role": "assistant", "tool_calls": [{"id": "headroom-local-output", "type": "function",
          "function": {"name": tool_name, "arguments": json.dumps(args)}}]},
        {"role": "tool", "tool_call_id": "headroom-local-output", "content": text},
    ]
    response = _post({
        "messages": messages,
        # Tokenizer estimate only: this endpoint never calls this model.
        "model": "gpt-4o",
        "config": {"protect_recent": 0, "protect_analysis_context": False,
                   "frozen_message_count": 0},
    })
    output = response.get("messages")
    if not isinstance(output, list) or len(output) != 2 or output[0] != messages[0]:
        return text
    if not isinstance(output[1], dict):
        return text
    candidate = output[1].get("content")
    if {k: v for k, v in output[1].items() if k != "content"} != {
        k: v for k, v in messages[1].items() if k != "content"
    }:
        return text
    if not isinstance(candidate, str) or not candidate or len(candidate) >= len(text):
        return text
    if response.get("ccr_hashes") or "<<ccr:" in candidate or "Retrieve more: hash=" in candidate:
        return text
    before, after = response.get("tokens_before"), response.get("tokens_after")
    if not isinstance(before, (int, float)) or not isinstance(after, (int, float)) or not 0 < after < before:
        return text
    return candidate


def compress_tool_output(*, tool_name, args, next_call, **context):
    # Execute exactly once, outside recovery handling: real tool failures propagate.
    original = next_call(args)
    try:
        name = tool_name.rsplit("__", 1)[-1].lower()
        if name in _READ_TOOLS:
            return original
        if name in _SHELL_TOOLS and _READ_COMMAND.search(str(args.get("command", args.get("cmd", "")))):
            return original
        # Hermes terminals return a JSON envelope. Preserve exit status, stderr,
        # session identifiers and every other field; compact only stdout/output.
        envelope = original
        serialized = isinstance(original, str)
        if serialized and name in _SHELL_TOOLS:
            try:
                envelope = json.loads(original)
            except ValueError:
                envelope = original
        if isinstance(envelope, dict) and name in _SHELL_TOOLS:
            if envelope.get("exit_code", envelope.get("returncode", 0)) not in (0, None):
                return original
            key = next((k for k in ("output", "stdout") if isinstance(envelope.get(k), str)), None)
            if key is None:
                return original
            content = _compress_text(envelope[key], tool_name, args)
            if content == envelope[key]:
                return original
            updated = dict(envelope, **{key: content})
            return json.dumps(updated, ensure_ascii=False) if serialized else updated
        if isinstance(original, str):
            return _compress_text(original, tool_name, args)
    except Exception:
        # Service outage, timeout or malformed response never retries the tool.
        return original
    return original


def register(ctx):
    ctx.register_middleware("tool_execution", compress_tool_output)
