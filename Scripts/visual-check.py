#!/usr/bin/env python3
"""Capture isolated, non-persistent native previews. Never reads keys/accounts."""
import pathlib, subprocess, tempfile, time, sys, os
root = pathlib.Path(__file__).resolve().parents[1]
binary = pathlib.Path(os.environ.get('LLM_USAGE_TEST_BINARY', str(root / '.build/debug/OpenAIQuotaBar')))
out = root / 'Artifacts'
out.mkdir(exist_ok=True)
names = [arg for arg in sys.argv[1:] if not arg.startswith('--')]
composite = '--composite' in sys.argv
for name, flags in [
    ('dashboard-light', ['--demo', '--detail', '--light']),
    ('dashboard-dark', ['--demo', '--detail', '--dark']),
    ('accounts-light', ['--five-accounts', '--light']),
    ('accounts-dark', ['--five-accounts', '--dark']),
    ('switch-light', ['--five-accounts', '--detail', '--light']),
    ('switch-dark', ['--five-accounts', '--detail', '--dark']),
    ('devices-light', ['--five-accounts', '--devices', '--light']),
    ('devices-dark', ['--five-accounts', '--devices', '--dark']),
    ('settings-light', ['--five-accounts', '--settings', '--light']),
    ('settings-dark', ['--five-accounts', '--settings', '--dark']),
    ('rename-light', ['--account-settings', '--light']),
    ('welcome-light', ['--light']),
    ('signin-light', ['--signin', '--light']),
    ('signin-dark', ['--signin', '--dark']),
    ('signin-error-light', ['--signin-error', '--light']),
    ('error-dark', ['--error', '--dark']),
    ('unfetched-light', ['--unfetched', '--light']),
    ('unlimited-light', ['--unlimited', '--light']),
    ('exhausted-dark', ['--exhausted', '--dark']),
    ('long-name-light', ['--long-name', '--light']),
]:
    if names and name not in names:
        continue
    with tempfile.TemporaryDirectory(prefix='quotabar-preview-') as scratch:
        window_id = pathlib.Path(scratch) / 'window-id'
        p = subprocess.Popen([str(binary), '--preview', *flags, '--window-id-file', str(window_id)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            for _ in range(60):
                if window_id.exists(): break
                if p.poll() is not None: raise RuntimeError(p.stderr.read().decode())
                time.sleep(0.1)
            time.sleep(0.8)
            if composite:
                script = f'tell application "System Events"\nset targetProcess to first application process whose unix id is {p.pid}\ntell targetProcess\nreturn {{position of window 1, size of window 1}}\nend tell\nend tell'
                bounds = subprocess.check_output(['osascript', '-e', script], text=True).strip().replace(' ', '')
                subprocess.run(['screencapture', '-x', '-R', bounds, str(out / (name + '-composited.png'))], check=True)
            else:
                subprocess.run(['screencapture', '-x', '-l', window_id.read_text().strip(), str(out / (name + '.png'))], check=True)
            print(name, 'captured', flush=True)
        finally:
            p.terminate()
            p.wait(timeout=5)
