import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--format', choices=['deb', 'rpm'], required=True)
parser.add_argument('--base', required=True)
parser.add_argument('--base-version', default='0.0.1')
parser.add_argument('--legacy-usb-setup', action='store_true')
parser.add_argument('--update', required=True)
parser.add_argument('--version', required=True)
parser.add_argument('--driver', required=True)
args = parser.parse_args()
assert os.getuid() == 0, 'Run only inside the disposable container'
app = Path('/usr/lib/chromagician')
manager = '/usr/bin/apt-get' if args.format == 'deb' else '/usr/bin/dnf'
env = dict(os.environ, GDK_BACKEND='x11', LIBGL_ALWAYS_SOFTWARE='1')
ack = Path('/usr/lib/.chromagician-update-test/started.json')
ack.parent.mkdir()
env['CHROMAGIC_UPDATE_ACK'] = str(ack)
prefs = Path('/root/.local/share/chromagician-installer-test/preferences')
prefs.parent.mkdir(parents=True)
prefs.write_text('keep')


def version():
    return json.loads((app / 'data/flutter_assets/version.json').read_text())['version']


def wait_ack(expected):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            data = json.loads(ack.read_text())
            if data['version'] == expected:
                return data
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.1)
    raise AssertionError('Actual Flutter app did not acknowledge startup: ' + expected)


subprocess.run([manager, '-y', 'install', args.base], check=True)
assert version() == args.base_version
assert (app / '.linux-package').read_text().strip() == args.format
desktop = Path('/usr/share/applications/org.chromagic.ChroMagician.desktop')
icon = Path('/usr/share/icons/hicolor/256x256/apps/org.chromagic.ChroMagician.png')
rule = Path('/usr/lib/udev/rules.d/70-chromagician.rules')
assert desktop.exists() and rule.exists() == args.legacy_usb_setup
assert 'Icon=org.chromagic.ChroMagician' in desktop.read_text()
assert icon.read_bytes() == (app / 'data/app_icon.png').read_bytes()
subprocess.run(['desktop-file-validate', str(desktop)], check=True)
assert app.stat().st_uid == 0 and not app.stat().st_mode & 0o022
old = subprocess.Popen(['/usr/bin/chromagician'], env=env)
new_pid = None
try:
    assert wait_ack(args.base_version)['pid'] == old.pid
    pkexec = Path('/usr/bin/pkexec')
    pkexec.write_text('#!/bin/sh\nexit 126\n')
    pkexec.chmod(0o755)
    command = [args.driver, str(app), args.update, args.version, '/tmp/update-cache', args.format]
    cancel = subprocess.run(command, env=env, text=True, capture_output=True)
    assert cancel.returncode != 0 and 'not authorized' in cancel.stderr, cancel
    assert version() == args.base_version and old.poll() is None
    wrong = command.copy()
    wrong[3] = '999.0.0'
    mismatch = subprocess.run(wrong, env=env, text=True, capture_output=True)
    assert mismatch.returncode != 0 and 'does not match' in mismatch.stderr, mismatch
    assert version() == args.base_version
    pkexec.write_text('#!/bin/sh\n"$@" > /tmp/package-manager-update.log 2>&1\nexit $?\n')
    pkexec.chmod(0o755)
    ack.unlink()
    updated = subprocess.run(command, env=env, text=True, capture_output=True)
    if updated.returncode:
        print(updated.stdout, updated.stderr)
        print(Path('/tmp/package-manager-update.log').read_text())
        raise AssertionError('Production native update failed')
    new_pid = wait_ack(args.version)['pid']
    assert new_pid != old.pid and old.poll() is None
    assert version() == args.version
    assert (app / '.linux-package').read_text().strip() == args.format
    assert not rule.exists()
    assert not (app / 'setup-usb.sh').exists()
    assert not (app / '70-chromagician.rules').exists()
    assert prefs.read_text() == 'keep'
    if args.format == 'deb':
        registered = subprocess.check_output(['dpkg-query', '-W', '-f=${Version}', 'chromagician'], text=True)
    else:
        registered = subprocess.check_output(['rpm', '-q', '--qf', '%{VERSION}', 'chromagician'], text=True)
    assert registered == args.version.replace('-', '~', 1), registered
    assert not list(Path('/tmp').glob('chromagician-package-*'))
finally:
    old.terminate()
    old.wait(timeout=10)
    if new_pid:
        os.kill(new_pid, signal.SIGTERM)
        time.sleep(.3)
subprocess.run([manager, '-y', 'remove', 'chromagician'], check=True)
assert not app.exists() and not desktop.exists() and not rule.exists() and not icon.exists()
assert not Path('/usr/bin/chromagician').exists()
assert prefs.read_text() == 'keep'
print('PASS', args.format, 'install, desktop entry, no custom USB setup, actual Flutter startup, cancellation, wrong-version rejection, native update, package registration, uninstall, retained user data')
