import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
parser.add_argument('--downloads')
parser.add_argument('--engine', choices=['podman', 'docker'],
                    default=os.environ.get('CHROMAGIC_CONTAINER_ENGINE', 'podman'))
args = parser.parse_args()
if platform.system() != 'Linux' or platform.machine() != 'x86_64':
    raise SystemExit('This flashing-tool package currently targets Linux x86_64.')
recipe = Path(__file__).resolve().parent / 'linux'
output = Path(args.output).resolve()
downloads = Path(args.downloads).resolve() if args.downloads else output.parent / 'linux-tools-downloads'
key = hashlib.sha256(Path(__file__).read_bytes() + b''.join(
    (recipe / name).read_bytes() for name in
    ('Containerfile', 'inputs.json', 'package_tools.py'))).hexdigest()
stamp = output / 'packaging.json'
sources_archive = output.parent / 'ChroMagician-linux-tools-sources.tar.gz'
if stamp.exists():
    saved = json.loads(stamp.read_text())
    if saved.get('key') == key and sources_archive.exists() and \
            hashlib.sha256(sources_archive.read_bytes()).hexdigest() == saved['source_sha256'] and all((output / f).is_file() and
            hashlib.sha256((output / f).read_bytes()).hexdigest() == sha
            for f, sha in saved['files'].items()):
        print('Verified cached Linux flashing tools.')
        raise SystemExit(0)
downloads.mkdir(parents=True, exist_ok=True)
for name, data in json.loads((recipe / 'inputs.json').read_text()).items():
    cached = downloads / (name + '.tar.gz')
    if not cached.exists() or hashlib.sha256(cached.read_bytes()).hexdigest() != data['sha256']:
        incoming = cached.with_suffix('.incoming')
        urllib.request.urlretrieve(data['url'], incoming)
        if hashlib.sha256(incoming.read_bytes()).hexdigest() != data['sha256']:
            incoming.unlink()
            raise SystemExit('Upstream tool download failed SHA-256 verification: ' + name)
        incoming.replace(cached)
image = 'localhost/chromagician-flashing-tools:' + key[:12]
build_limits = ['--cpu-period', '100000', '--cpu-quota', '200000', '--memory', '3g'] if args.engine == 'podman' else []
subprocess.run([args.engine, 'build', *build_limits, '-f', str(recipe / 'Containerfile'),
    '-t', image, str(recipe)], check=True)
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.linux-tools-', dir=output.parent) as tmp:
    stage = Path(tmp)
    identity = ['--user', f'{os.getuid()}:{os.getgid()}', '--tmpfs', '/work:mode=1777'] if args.engine == 'docker' else []
    subprocess.run([args.engine, 'run', '--rm', *identity, '--cpus', '2', '--memory', '3g',
        '--security-opt', 'label=disable',
        '-v', f'{recipe}:/recipe:ro', '-v', f'{downloads}:/downloads:ro',
        '-v', f'{stage}:/out:rw', image, 'python3', '/recipe/package_tools.py'], check=True)
    with tarfile.open(sources_archive, 'w:gz', compresslevel=3) as tf:
        tf.add(stage / 'sources', arcname='ChroMagician-linux-tools-sources')
    package = stage / 'firmware'
    files = {str(f.relative_to(package)): hashlib.sha256(f.read_bytes()).hexdigest()
        for f in sorted(package.rglob('*')) if f.is_file()}
    (package / 'packaging.json').write_text(json.dumps({'key': key, 'files': files,
        'source_sha256': hashlib.sha256(sources_archive.read_bytes()).hexdigest()}, indent=2) + '\n')
    if output.exists(): shutil.rmtree(output)
    package.rename(output)
print('Packaged Linux flashing tools:', output)
