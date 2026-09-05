import json, sys, time
from pathlib import Path

completed_login = False

def emit(message, fragmented=False):
    text = json.dumps(message) + '\n'
    if fragmented:
        for part in [text[:7], text[7:19], text[19:]]:
            sys.stdout.write(part)
            sys.stdout.flush()
            time.sleep(.005)
    else:
        sys.stdout.write(text)
        sys.stdout.flush()

for line in sys.stdin:
    message = json.loads(line)
    if 'id' not in message:
        continue
    method = message['method']
    behavior = (message.get('params') or {}).get('_test')
    if behavior == 'timeout': continue
    if behavior == 'disconnect': sys.exit(0)
    if behavior == 'error':
        emit({'id': message['id'], 'error': {'code': -1, 'message': 'authentication failed secret-value-must-not-appear'}})
        continue
    if method == 'initialize': result = {'userAgent': 'fake'}
    elif method == 'account/read':
        account = {'type': 'chatgpt', 'email': 'test@example.com', 'planType': 'pro'}
        if '--account-unavailable' in sys.argv or ('--stale-after-login' in sys.argv and completed_login):
            account = None
        if '--delayed-account' in sys.argv:
            counter = Path('identity-read-count')
            reads = int(counter.read_text()) + 1 if counter.exists() else 1
            counter.write_text(str(reads))
            if reads <= 2: account = None
        result = {'account': account, 'requiresOpenaiAuth': True}
    elif method == 'account/login/start': result = {'type': 'chatgptDeviceCode', 'loginId': 'test-login', 'verificationUrl': 'https://auth.openai.com/codex/device', 'userCode': 'TEST-CODE'}
    elif method == 'account/rateLimits/read': result = {'rateLimits': {'limitId': 'codex', 'primary': {'usedPercent': 28, 'windowDurationMins': 300, 'resetsAt': 2000000000}}, 'rateLimitResetCredits': {'availableCount': 2}}
    else: result = {}
    emit({'id': message['id'], 'result': result}, behavior == 'fragmented')
    if method == 'account/login/start' and '--no-complete' not in sys.argv:
        completed_login = True
        emit({'method': 'account/login/completed', 'params': {'loginId': 'test-login', 'success': True, 'error': None}})
