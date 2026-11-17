#!/usr/bin/env python3
"""Read-only statistics and subscription quotas. Credentials stay on this machine."""
import concurrent.futures
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import selectors
import shutil
import subprocess
import time
import urllib.error
import urllib.request

MAX_FILES = 1500
MAX_BYTES = 256 * 1024 * 1024
MAX_LINE = 2 * 1024 * 1024


def safe_text(value, limit=120):
    return ''.join(c for c in value if c.isprintable())[:limit] if isinstance(value, str) else None


def json_file(path):
    try:
        if path.stat().st_size > 2 * 1024 * 1024:
            return {}
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def quota_window(name, percent, reset):
    if isinstance(percent, bool) or not isinstance(percent, (int, float)) or not math.isfinite(percent):
        return None
    when = timestamp(reset) if isinstance(reset, str) else reset
    if isinstance(when, bool) or not isinstance(when, (int, float)) or not math.isfinite(when):
        when = None
    return {'name': name, 'remainingPercent': round(max(0, min(100, 100-percent)), 2), 'resetsAt': when}


def claude_windows(data):
    windows = []
    for key, name in [('five_hour', '5-hour'), ('seven_day', 'Weekly')]:
        bucket = data.get(key)
        if isinstance(bucket, dict):
            windows.append(quota_window(name, bucket.get('utilization'), bucket.get('resets_at')))
    scoped = []
    for limit in data.get('limits') or []:
        if not isinstance(limit, dict) or limit.get('kind') != 'weekly_scoped':
            continue
        model = ((limit.get('scope') or {}).get('model') or {})
        name = safe_text(model.get('display_name'))
        if name:
            scoped.append(quota_window(name + ' · weekly', limit.get('percent'), limit.get('resets_at')))
    if not any(scoped):
        for key, name in [('seven_day_opus', 'Opus · weekly'), ('seven_day_sonnet', 'Sonnet · weekly')]:
            bucket = data.get(key)
            if isinstance(bucket, dict):
                scoped.append(quota_window(name, bucket.get('utilization'), bucket.get('resets_at')))
    return [w for w in windows + scoped if w][:12]


def codex_windows(data):
    limits = (data.get('rateLimitsByLimitId') or {}).get('codex')
    if not isinstance(limits, dict):
        limits = data.get('rateLimits') or {}
        if limits.get('limitId') not in (None, 'codex'):
            return []
    windows = []
    for key in ['primary', 'secondary']:
        window = limits.get(key)
        if not isinstance(window, dict):
            continue
        minutes = window.get('windowDurationMins')
        name = 'Weekly' if minutes == 10080 else '5-hour' if minutes == 300 else 'Current window'
        windows.append(quota_window(name, window.get('usedPercent'), window.get('resetsAt')))
    return [w for w in windows if w]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a bearer token to another destination.
        return None


def claude_get(endpoint, token):
    assert endpoint in ('profile', 'usage')
    request = urllib.request.Request('https://api.anthropic.com/api/oauth/' + endpoint,
        headers={'Authorization': 'Bearer ' + token, 'anthropic-beta': 'oauth-2025-04-20', 'Accept': 'application/json'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=5) as response:
        data = json.loads(response.read(1_000_000))
    if not isinstance(data, dict):
        raise ValueError('Invalid provider response')
    return data


def claude_credentials(home, config_dir=None):
    service = 'Claude Code-credentials'
    if config_dir:
        service += '-' + hashlib.sha256(str(config_dir).encode()).hexdigest()[:8]
    document = {}
    if platform.system() == 'Darwin':
        try:
            result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', service, '-w'],
                capture_output=True, timeout=4, check=True)
            document = json.loads(result.stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    if not isinstance(document, dict) or not document.get('claudeAiOauth'):
        document = json_file(Path(config_dir or home / '.claude') / '.credentials.json')
    oauth = document.get('claudeAiOauth') if isinstance(document, dict) else None
    return oauth if isinstance(oauth, dict) else {}


def account_result(profile):
    return {'id': profile['id'], 'provider': profile['provider'], 'profile': profile['label'],
            'isDefault': profile['default'], 'status': 'unavailable', 'email': None,
            'plan': None, 'windows': [], 'checkedAt': time.time(), 'message': None}


def read_claude_account(profile, home):
    result = account_result(profile)
    credentials = claude_credentials(home, profile.get('directory'))
    token = credentials.get('accessToken')
    if not isinstance(token, str) or not token:
        result['message'] = 'Sign-in unavailable. Sign in or unlock the login keychain on this machine.'
        return result
    try:
        identity = claude_get('profile', token)
        account = identity.get('account') or {}
        email = safe_text(account.get('email'))
        expected = profile.get('email')
        if expected and (email or '').casefold() != expected.casefold():
            result['message'] = 'The saved profile changed accounts. Reconnect it on this machine.'
            return result
        result['email'] = email
        result['status'] = 'connected'
        organization = identity.get('organization') or {}
        result['plan'] = safe_text(organization.get('rate_limit_tier') or organization.get('organization_type') or credentials.get('subscriptionType'))
        result['windows'] = claude_windows(claude_get('usage', token))
        if not result['windows']:
            result['message'] = 'The provider did not return subscription limits.'
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            result['status'] = 'expired'
            result['message'] = 'Sign-in needs renewal on this machine. No credentials were changed.'
        elif error.code == 429:
            result['message'] = 'Quota requests are temporarily limited. Try again later.'
        else:
            result['message'] = 'The provider could not return this quota.'
    except (OSError, ValueError, TypeError, AttributeError):
        result['message'] = 'The provider could not return this quota.'
    return result


def cli_environment(home):
    env = os.environ.copy()
    for key in ['OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'OPENAI_BASE_URL', 'CHATGPT_BASE_URL',
                'CODEX_HOME', 'CODEX_MANAGED_BY_NPM', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE']:
        env.pop(key, None)
    paths = [str(home / p) for p in ['.local/bin', '.local/node/bin', '.npm-global/bin', '.volta/bin', '.bun/bin',
        '.codex/packages/standalone/current/bin', '.codex/packages/standalone/current']]
    paths += [p for p in env.get('PATH', '').split(':') if p.startswith('/')]
    paths += ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']
    env['PATH'] = ':'.join(dict.fromkeys(paths))
    env['RUST_LOG'] = 'off'
    return env


class CodexReader:
    """Only account reads over stdio; no login, grants, turns or model calls."""
    def __init__(self, executable, directory, env, private=False):
        args = [executable] + (['-c', 'cli_auth_credentials_store="keyring"'] if private else [])
        self.process = subprocess.Popen(args + ['app-server', '--listen', 'stdio://'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            cwd=directory, env=dict(env, CODEX_HOME=str(directory)), start_new_session=True)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.next_id = 0
        self.deadline = time.monotonic() + 12

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b'\n')
        self.process.stdin.flush()

    def request(self, method, params=None):
        assert method in ('initialize', 'account/read', 'account/rateLimits/read')
        self.next_id += 1
        self.send({'id': self.next_id, 'method': method, 'params': params or {}})
        while time.monotonic() < self.deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                message = json.loads(line)
                if 'method' in message:
                    if 'id' in message:
                        self.send({'id': message['id'], 'error': {'code': -32601, 'message': 'Read-only monitor'}})
                elif message.get('id') == self.next_id:
                    if 'error' in message:
                        raise ValueError('Account read unavailable')
                    return message.get('result') or {}
            if self.selector.select(max(0, self.deadline-time.monotonic())):
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    break
                self.buffer += chunk
                if len(self.buffer) > 1_000_000:
                    break
        raise TimeoutError('Account read timed out')

    def close(self):
        self.selector.close()
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            if self.process.poll() is None:
                self.process.terminate()
            self.process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=1)
        finally:
            self.process.stdout.close()


def read_codex_account(profile, home):
    result = account_result(profile)
    directory = Path(profile['directory'])
    env = cli_environment(home)
    executable = shutil.which('codex', path=env['PATH'])
    if not executable or not directory.is_dir():
        result['message'] = 'Codex or its sign-in profile is unavailable on this machine.'
        return result
    reader = None
    try:
        reader = CodexReader(executable, directory, env, private=not profile['default'])
        reader.request('initialize', {'clientInfo': {'name': 'llm_usage_monitor', 'title': 'LLM Usage', 'version': '4.10.0'}})
        reader.send({'method': 'initialized', 'params': {}})
        identity = reader.request('account/read', {'refreshToken': False}).get('account')
        if not isinstance(identity, dict):
            result['status'] = 'signedOut'
            result['message'] = 'Codex is not signed in on this machine.'
            return result
        if identity.get('type') != 'chatgpt':
            result['status'] = 'apiKey'
            result['message'] = 'API key session; no ChatGPT subscription balance is available.'
            return result
        email = safe_text(identity.get('email'))
        if profile.get('email') and (email or '').casefold() != profile['email'].casefold():
            result['message'] = 'The saved profile changed accounts. Reconnect it on this machine.'
            return result
        result.update(status='connected', email=email, plan=safe_text(identity.get('planType')))
        result['windows'] = codex_windows(reader.request('account/rateLimits/read'))
        confirmed = reader.request('account/read', {'refreshToken': False}).get('account') or {}
        if confirmed.get('type') != 'chatgpt' or (confirmed.get('email') or '').casefold() != (email or '').casefold():
            result.update(status='unavailable', email=None, plan=None, windows=[],
                          message='Codex changed accounts during the reading. Refresh again.')
            return result
        if not result['windows']:
            result['message'] = 'The provider did not return subscription limits.'
    except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
        result['message'] = 'Codex could not read the quota. Check its sign-in on this machine.'
    finally:
        if reader:
            reader.close()
    return result


def account_profiles(home):
    profiles = [dict(id='claude-default', provider='claude', label='Default Claude Code', default=True),
                dict(id='codex-default', provider='codex', label='Default Codex', default=True, directory=str(home / '.codex'))]
    support = home / 'Library/Application Support/OpenAIQuotaBar'
    try:
        if (support / 'accounts.json').stat().st_size > 2 * 1024 * 1024:
            return profiles
        saved = json.loads((support / 'accounts.json').read_text())
        if not isinstance(saved, list):
            return profiles
        for record in saved:
            if not isinstance(record, dict):
                continue
            provider = record.get('connection')
            if provider == 'claude' and record.get('claudeConfigDir'):
                directory = Path(record['claudeConfigDir'])
            elif provider == 'codex' and not record.get('usesLocalCodex'):
                directory = support / 'Sessions' / (record.get('authSessionID') or record.get('id', ''))
            else:
                continue
            if not directory.resolve().is_relative_to(home.resolve()) or not directory.is_dir():
                continue
            profiles.append(dict(id=provider+'-'+hashlib.sha256(str(directory).encode()).hexdigest()[:12],
                provider=provider, label='LLM Usage · '+(safe_text(record.get('name')) or provider), default=False,
                directory=str(directory), email=safe_text(record.get('email'))))
    except (OSError, ValueError, TypeError):
        pass
    return profiles[:8]


def connected_accounts(home):
    profiles = account_profiles(home)
    # Independent failures do not hide token logs or the other provider's account.
    def read(profile):
        try:
            return (read_claude_account if profile['provider'] == 'claude' else read_codex_account)(profile, home)
        except Exception:
            result = account_result(profile)
            result['message'] = 'Account information is temporarily unavailable.'
            return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        return list(pool.map(read, profiles))


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
            'accounts': connected_accounts(home),
            'sources': {'codex': (home / '.codex/sessions').is_dir(), 'claude': (home / '.claude/projects').is_dir()}}


if __name__ == '__main__':
    print(json.dumps(collect(), separators=(',', ':')))
