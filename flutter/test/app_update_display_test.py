import argparse
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--bundle', required=True)
parser.add_argument('--release-json', required=True)
parser.add_argument('--xvfb', required=True)
parser.add_argument('--inner', action='store_true')
args = parser.parse_args()

if not args.inner:
    env = dict(os.environ)
    gh = shutil.which('gh') or str(Path.home() / '.local/bin/gh')
    env['CHROMAGIC_GITHUB_TOKEN'] = subprocess.check_output(
        [gh, 'auth', 'token', '--hostname', 'github.com'], text=True).strip()
    sys.exit(subprocess.call(['dbus-run-session', '--', sys.executable,
        __file__, *sys.argv[1:], '--inner'], env=env))

release = json.loads(Path(args.release_json).read_text())
expected = release['tag_name'].removeprefix('v')
version_path = Path('data/flutter_assets/version.json')
with tempfile.TemporaryDirectory(prefix='app-update-display-') as temp:
    root = Path(temp)
    target = root / 'live app'
    shutil.copytree(args.bundle, target)
    previous = json.loads((target / version_path).read_text())['version']
    assert previous != expected, 'Supply an older installed app'
    env = dict(os.environ)
    for key in ('DATA', 'CONFIG', 'CACHE', 'RUNTIME'):
        folder = root / key.lower()
        folder.mkdir(mode=0o700)
        env[f'XDG_{key}_HOME' if key != 'RUNTIME' else 'XDG_RUNTIME_DIR'] = str(folder)
    env.pop('WAYLAND_DISPLAY', None)
    env['GDK_BACKEND'] = 'x11'
    env['LIBGL_ALWAYS_SOFTWARE'] = '1'
    sentinel = root / 'data' / 'keep-preferences'
    sentinel.write_text('unchanged')
    stub = root / 'no-usb'
    stub.write_text('#!/bin/sh\nprintf \'{"schema_version":1,"event":"devices","ports":[]}\\n\'\n')
    stub.chmod(0o700)
    env['CHROMATIC_BACKUP_BIN'] = str(stub)
    env.pop('CHROMAGIC_UPDATE_ACK', None)
    env.pop('CHROMAGIC_UPDATE_FAILED', None)
    driver = None
    with (root / 'display.log').open('w+') as log:
        display = subprocess.Popen([args.xvfb, '-displayfd', '1', '-screen',
            '0', '1280x1024x24', '-nolisten', 'tcp'], stdout=subprocess.PIPE,
            stderr=log, text=True, env=env)
        try:
            assert select.select([display.stdout], [], [], 10)[0], 'Display startup timed out'
            number = display.stdout.readline().strip()
            assert number.isdigit(), 'Display failed to start'
            env['DISPLAY'] = ':' + number
            driver = subprocess.Popen(['dart', 'run', 'test/support/app_update_driver.dart',
                str(target), str(Path(args.release_json).resolve()), str(root / 'downloads')],
                env=env, stdout=log, stderr=log)
            assert driver.wait(timeout=90) == 0, 'Update download/handoff failed'
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                stages = list(root.glob('.chromagician-update-*'))
                if target.exists() and not stages:
                    actual = json.loads((target / version_path).read_text())['version']
                    assert actual == expected, f'Update rolled back to {actual}'
                    break
                time.sleep(0.1)
            else:
                raise AssertionError('Packaged app did not acknowledge startup')
            assert sentinel.read_text() == 'unchanged'
            assert list((target / 'firmware').rglob('*.fs')) == []
            assert list((target / 'firmware').rglob('*.bin')) == []
            print(json.dumps({'from': previous, 'to': actual,
                'verified_github_download': True, 'packaged_flutter_started': True,
                'preferences_preserved': True, 'firmware_images_bundled': False}))
        except Exception:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            if driver and driver.poll() is None:
                driver.kill()
                driver.wait()
            for proc in Path('/proc').iterdir():
                if not proc.name.isdigit():
                    continue
                try:
                    exe = os.readlink(proc / 'exe').removesuffix(' (deleted)')
                    if exe.startswith(str(root) + '/'):
                        os.kill(int(proc.name), signal.SIGTERM)
                except (FileNotFoundError, PermissionError, ProcessLookupError):
                    pass
            display.terminate()
            display.wait(timeout=10)
