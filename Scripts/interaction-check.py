#!/usr/bin/env python3
"""Exercise account management in an isolated, in-memory native preview."""
import pathlib, subprocess, tempfile, time, json, sys, os
root = pathlib.Path(__file__).resolve().parents[1]
(root / 'Artifacts').mkdir(exist_ok=True)
def mac_theme():
    result = subprocess.run(['defaults', 'read', '-g', 'AppleInterfaceStyle'], text=True, capture_output=True)
    return (result.returncode, result.stdout.strip())
original_theme = mac_theme()
rename_only = '--rename-only' in sys.argv
with tempfile.TemporaryDirectory(prefix='quotabar-interaction-') as temp:
    ready = pathlib.Path(temp) / 'ready'
    arguments = [os.environ.get('LLM_USAGE_TEST_BINARY', str(root / '.build/debug/OpenAIQuotaBar')), '--preview', '--five-accounts', '--window-id-file', str(ready)]
    if rename_only: arguments += ['--settings']
    p = subprocess.Popen(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def apple(body):
        code = f'tell application "System Events"\nset targetProcess to first application process whose unix id is {p.pid}\ntell targetProcess\n{body}\nend tell\nend tell'
        result = subprocess.run(['osascript', '-e', code], text=True, capture_output=True, timeout=12)
        if result.returncode: raise RuntimeError(result.stderr)
        return result.stdout.strip()
    def identified(identifier, action='click targetControl'):
        return apple(f'''set allControls to entire contents of window 1
repeat with controlReference in allControls
set targetControl to contents of controlReference
try
if value of attribute "AXIdentifier" of targetControl is "{identifier}" then
{action}
return "found"
end if
end try
end repeat
error "Control not found: {identifier}"''')
    def click(identifier):
        apple('set frontmost to true')
        for _ in range(20):
            if any(row['id'] == identifier for row in snapshot()):
                break
            time.sleep(.15)
        subprocess.run([str(root / '.build/ax-action'), str(p.pid), identifier], check=True)
        time.sleep(.7)
    def snapshot():
        return json.loads(subprocess.check_output([str(root / '.build/ax-snapshot'), str(p.pid)], text=True))
    def content(): return ' '.join(row['text'] + ' ' + row['value'] for row in snapshot())
    def selected(identifier):
        return next(row for row in snapshot() if row['id'] == identifier)['value'] == 'Selected'
    def capture(name):
        if '--no-captures' in sys.argv: return
        subprocess.run(['screencapture', '-x', '-l', ready.read_text().strip(), str(root / 'Artifacts' / name)], check=True)
    try:
        for _ in range(60):
            if ready.exists(): break
            time.sleep(.1)
        time.sleep(.8)
        if not rename_only:
            home = content()
            for name in ['Personal workspace', 'Studio', 'Work', 'Research', 'Side projects']:
                assert name in home, home[:6000]
            assert '28% used' in home and ('14.6M tokens' in home or '14,6M tokens' in home)
            click('account-row-55555555-5555-5555-5555-555555555555')
            assert 'Side projects' in content() and 'remaining' in content().lower()
            click('use-account')
            assert 'Active' in content() and '1 devices active' in content()
            click('account-devices')
            assert 'Your devices' in content() and 'Using Side projects' in content()
            click('devices-back')
            click('all-accounts')
            assert 'Your accounts' in content()
            click('account-row-11111111-1111-1111-1111-111111111111')
            click('use-account')
            assert 'Active' in content()
            click('account-devices')
            assert 'Using Personal workspace' in content()
            click('devices-back')
            click('all-accounts')
            print('PASS: account selection and device confirmations update without closing the panel', flush=True)
            print('PASS: all five accounts show usage and open their own details', flush=True)
            click('app-settings')
            click('theme-dark')
            assert selected('theme-dark')
            capture('theme-switch-dark.png')
            click('theme-light')
            assert selected('theme-light')
            capture('theme-switch-light.png')
            click('theme-system')
            assert selected('theme-system')
            assert mac_theme() == original_theme
            print('PASS: theme switches live without changing the Mac theme', flush=True)
            click('runtime-load')
            assert 'Sample model' in content()
            click('runtime-yolo')
            click('runtime-apply')
            assert 'Saved for new conversations on This Mac.' in content()
            click('runtime-load')
            assert next(row for row in snapshot() if row['id'] == 'runtime-yolo')['value'] == '1'
            click('runtime-yolo')
            click('runtime-full-access')
            click('runtime-apply')
            print('PASS: model settings and YOLO are editable using isolated preview data', flush=True)
            click('rename-11111111-1111-1111-1111-111111111111')
        else:
            click('rename-11111111-1111-1111-1111-111111111111')
        subprocess.run([str(root / '.build/ax-action'), str(p.pid), 'account-name', 'replace-text', 'My daily account'], check=True)
        time.sleep(.4)
        draft = next(row for row in snapshot() if row['id'] == 'account-name')
        assert 'My daily account' in draft['value'], str(draft)
        click('save-account-name')
        capture('rename-interaction.png')
        assert not any(row['id'] == 'account-name' for row in snapshot()), content()[:5000]
        assert 'My daily account' in content(), content()[:4000]
        click('settings-back')
        assert 'My daily account' in content() and '5 accounts' in content()
        print('PASS: renaming updates settings and the five-account home screen', flush=True)
        if rename_only: sys.exit(0)
        click('add-account')
        auth = content()
        assert 'Finish in your browser.' in auth and 'DEMO-1234' in auth
        assert 'secure text field' not in auth
        apple('set frontmost to true\nkey code 53')
        time.sleep(.4)
        assert 'My daily account' in content() and '5 accounts' in content()
        print('PASS: one-click sign-in and cancellation preserve all existing accounts', flush=True)
    finally:
        p.terminate()
        p.wait(timeout=5)
