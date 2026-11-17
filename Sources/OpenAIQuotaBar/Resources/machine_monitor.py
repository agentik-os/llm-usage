#!/usr/bin/env python3
"""Read-only machine statistics. Never reads auth files or returns conversation text."""
import datetime as dt
import json
import os
from pathlib import Path
import platform
import subprocess
import time
import urllib.request

MAX_FILES = 1500
MAX_BYTES = 256 * 1024 * 1024
MAX_LINE = 2 * 1024 * 1024


def timestamp(value):
    try:
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError):
        return None


def number(value):
    return max(0, value) if isinstance(value, int) and not isinstance(value, bool) else 0


def summary(provider):
    return {'provider': provider, 'tokens24h': 0, 'tokens7d': 0, 'input7d': 0,
            'output7d': 0, 'cached7d': 0, 'lastActivity': None, 'sessions7d': 0}


def add(result, usage, when, now):
    if when is None or when > now + 300 or when < now - 7 * 86400:
        return False
    total, inputs, outputs, cached = usage
    result['tokens7d'] += total
    result['input7d'] += inputs
    result['output7d'] += outputs
    result['cached7d'] += cached
    if when >= now - 86400:
        result['tokens24h'] += total
    result['lastActivity'] = max(result['lastActivity'] or 0, when)
    return total > 0


def events(path, budget):
    try:
        with path.open('rb') as handle:
            while budget['bytes'] < MAX_BYTES:
                line = handle.readline(MAX_LINE + 1)
                if not line:
                    return
                budget['bytes'] += len(line)
                if len(line) > MAX_LINE:
                    budget['limited'] = True
                    # Discard the remainder without parsing partial prompt text.
                    while line and not line.endswith(b'\n'):
                        line = handle.readline(MAX_LINE + 1)
                        budget['bytes'] += len(line)
                        if budget['bytes'] >= MAX_BYTES:
                            return
                    continue
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        yield value
                except (ValueError, UnicodeError):
                    continue
            budget['limited'] = True
    except OSError:
        budget['limited'] = True


def recent_files(roots, now, budget):
    found = []
    for root in roots:
        if root.is_symlink():
            continue
        for parent, dirs, names in os.walk(root, followlinks=False):
            dirs[:] = [d for d in dirs if not (Path(parent) / d).is_symlink()]
            for name in names:
                if not name.endswith('.jsonl'):
                    continue
                path = Path(parent) / name
                try:
                    if path.is_symlink() or path.stat().st_mtime < now - 7 * 86400:
                        continue
                    found.append((path.stat().st_mtime, path))
                except OSError:
                    continue
    if len(found) > MAX_FILES:
        budget['limited'] = True
    return [p for _, p in sorted(found, key=lambda item: item[0], reverse=True)[:MAX_FILES]]


def codex_usage(files, now, budget):
    result = summary('codex')
    sessions = set()
    # Same session copied to an archive is read only once.
    seen_sessions = set()
    for path in files:
        previous = [0, 0, 0, 0]
        session = str(path)
        active = False
        for event in events(path, budget):
            payload = event.get('payload') or {}
            if not isinstance(payload, dict):
                continue
            if event.get('type') == 'session_meta':
                session = payload.get('id') or session
                if session in seen_sessions:
                    break
                seen_sessions.add(session)
            if event.get('type') != 'event_msg' or payload.get('type') != 'token_count':
                continue
            info = payload.get('info') or {}
            if not isinstance(info, dict):
                continue
            values = info.get('total_token_usage')
            if not isinstance(values, dict):
                continue
            inputs, outputs, cached = (number(values.get(k)) for k in ('input_tokens', 'output_tokens', 'cached_input_tokens'))
            total = number(values.get('total_tokens')) or inputs + outputs
            current = [total, inputs, outputs, cached]
            delta = [max(0, a - b) for a, b in zip(current, previous)]
            # Baseline includes events outside the window, preventing historical
            # cumulative totals from being reported as today's consumption.
            previous = [max(a, b) for a, b in zip(current, previous)]
            active = add(result, delta, timestamp(event.get('timestamp')), now) or active
        if active:
            sessions.add(session)
    result['sessions7d'] = len(sessions)
    return result


def claude_usage(files, now, budget):
    result = summary('claude')
    messages = {}
    sessions = set()
    for path in files:
        for event in events(path, budget):
            message = event.get('message')
            if event.get('type') != 'assistant' or not isinstance(message, dict):
                continue
            values = message.get('usage')
            when = timestamp(event.get('timestamp'))
            if not isinstance(values, dict) or when is None or when < now - 7 * 86400:
                continue
            inputs = number(values.get('input_tokens')) + number(values.get('cache_creation_input_tokens')) + number(values.get('cache_read_input_tokens'))
            outputs = number(values.get('output_tokens'))
            cached = number(values.get('cache_read_input_tokens'))
            key = (message.get('id'), event.get('requestId'))
            if not key[0]:
                # Without a message id, repeated snapshots cannot be deduplicated reliably.
                budget['limited'] = True
                continue
            current = (inputs + outputs, inputs, outputs, cached)
            old = messages.get(key)
            if old is None or current[0] > old[0][0]:
                messages[key] = (current, when, event.get('sessionId') or str(path))
    for usage, when, session in messages.values():
        if add(result, usage, when, now):
            sessions.add(session)
    result['sessions7d'] = len(sessions)
    return result


def agents():
    counts = {'codex': 0, 'claude': 0, 'hermes': 0, 'opencode': 0}
    try:
        lines = subprocess.run(['/bin/ps', '-u', str(os.getuid()), '-o', 'command='], capture_output=True, text=True, timeout=4, check=True).stdout.splitlines()
        for line in lines:
            parts = line.split()
            if not parts:
                continue
            name, args = Path(parts[0]).name, parts[1:]
            if name == 'codex' and 'app-server' not in args:
                counts['codex'] += 1
            elif (name == 'claude' or '/claude/versions/' in parts[0]) and not any(a in ('auth', 'daemon', 'mcp') or a.startswith(('--bg-', 'bg-')) for a in args):
                counts['claude'] += 1
            elif name.startswith('python') and 'hermes_cli.main' in args:
                counts['hermes'] += 1
            elif name == 'opencode' and 'serve' not in args:
                counts['opencode'] += 1
        return counts
    except (OSError, subprocess.SubprocessError):
        return None


def local_models():
    try:
        # Ignore proxy environment variables: never send localhost inventory via a proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open('http://127.0.0.1:11434/api/ps', timeout=2) as response:
            data = json.load(response)
        return [{'name': str(m.get('name', ''))[:120], 'memoryBytes': number(m.get('size_vram'))} for m in data.get('models', [])[:30]]
    except (OSError, ValueError):
        return None


def collect(home=None, now=None):
    home, now = Path(home or Path.home()), now or time.time()
    budget = {'bytes': 0, 'limited': False}
    codex = recent_files([home / '.codex/sessions', home / '.codex/archived_sessions'], now, budget)
    claude = recent_files([home / '.claude/projects'], now, budget)
    usage = [codex_usage(codex, now, budget), claude_usage(claude, now, budget)]
    return {'version': 1, 'hostname': platform.node(), 'platform': platform.system(), 'collectedAt': now,
            'agents': agents(), 'models': local_models(), 'usage': usage, 'partial': budget['limited'],
            'sources': {'codex': (home / '.codex/sessions').is_dir(), 'claude': (home / '.claude/projects').is_dir()}}


if __name__ == '__main__':
    print(json.dumps(collect(), separators=(',', ':')))
