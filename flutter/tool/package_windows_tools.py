import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    parser.add_argument('--downloads')
    parser.add_argument('--engine', choices=['podman', 'docker'], default='podman')
    args = parser.parse_args()
    tool = Path(__file__).resolve().parent
    recipe = tool / 'windows'
    output = Path(args.output).resolve()
    downloads = Path(args.downloads).resolve() if args.downloads else output.parent / 'windows-tools-downloads'
    shared = json.loads((tool / 'linux/inputs.json').read_text())
    inputs = {k: shared[k] for k in ('esptool_source', 'openFPGALoader')}
    inputs.update(json.loads((recipe / 'inputs.json').read_text()))
    key = hashlib.sha256(Path(__file__).read_bytes() + json.dumps(inputs, sort_keys=True).encode() +
        b''.join((recipe / name).read_bytes() for name in ('Containerfile', 'package_tools.py'))).hexdigest()
    sources_archive = output.parent / 'ChroMagician-windows-tools-sources.tar.gz'
    stamp = output / 'packaging.json'
    if stamp.exists():
        saved = json.loads(stamp.read_text())
        if saved.get('key') == key and sources_archive.exists() and digest(sources_archive) == saved['source_sha256'] and all(
            (output / f).is_file() and digest(output / f) == sha for f, sha in saved['files'].items()):
            print('Verified cached Windows flashing tools.')
            return
    downloads.mkdir(parents=True, exist_ok=True)
    for name, data in inputs.items():
        cached = downloads / name
        if not cached.exists() or digest(cached) != data['sha256']:
            incoming = cached.with_suffix('.incoming')
            urllib.request.urlretrieve(data['url'], incoming)
            if digest(incoming) != data['sha256']:
                incoming.unlink()
                raise RuntimeError('Upstream tool download failed SHA-256 verification: ' + name)
            incoming.replace(cached)
    image = 'localhost/chromagician-windows-tools:' + key[:12]
    subprocess.run([args.engine, 'build', '-f', str(recipe / 'Containerfile'),
        '-t', image, str(recipe)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.windows-tools-', dir=output.parent) as tmp:
        stage = Path(tmp)
        (stage / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
        identity = ['--user', f'{os.getuid()}:{os.getgid()}'] if args.engine == 'docker' else []
        subprocess.run([args.engine, 'run', '--rm', *identity, '--cpus', '2', '--memory', '3g',
            '--security-opt', 'label=disable', '-v', f'{tool}:/recipe:ro',
            '-v', f'{downloads}:/downloads:ro', '-v', f'{stage}:/out:rw',
            image, 'python3', '/recipe/windows/package_tools.py'], check=True)
        with tarfile.open(sources_archive, 'w:gz', compresslevel=3) as tf:
            tf.add(stage / 'sources', arcname='ChroMagician-windows-tools-sources')
        package = stage / 'firmware'
        files = {f.relative_to(package).as_posix(): digest(f) for f in sorted(package.rglob('*')) if f.is_file()}
        (package / 'packaging.json').write_text(json.dumps({'key': key, 'files': files,
            'source_sha256': digest(sources_archive)}, indent=2) + '\n')
        if output.exists():
            shutil.rmtree(output)
        package.rename(output)
    print('Packaged Windows flashing tools:', output)


if __name__ == '__main__':
    main()
