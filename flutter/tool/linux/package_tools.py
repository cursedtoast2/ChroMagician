import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

from PyInstaller.archive.readers import CArchiveReader

inputs = json.loads(Path('/recipe/inputs.json').read_text())
out = Path('/out/firmware')
tools = out / 'tools'
licenses = out / 'licenses'
sources = Path('/out/sources')
for folder in (tools / 'bin', tools / 'lib', licenses, sources):
    folder.mkdir(parents=True, exist_ok=True)

for name in inputs:
    archive = Path('/downloads') / (name + '.tar.gz')
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == inputs[name]['sha256']
    with tarfile.open(archive) as tf:
        tf.extractall('/work', filter='data')
    if name != 'esptool':
        shutil.copy2(archive, sources / archive.name)

src = Path('/work') / ('openFPGALoader-' + inputs['openFPGALoader']['revision'])
subprocess.run(['cmake', '-S', str(src), '-B', '/work/build',
    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_INSTALL_PREFIX=/work/install'], check=True)
subprocess.run(['cmake', '--build', '/work/build', '--parallel', '2'], check=True)
subprocess.run(['cmake', '--install', '/work/build'], check=True)
program = tools / 'bin/openFPGALoader'
shutil.copy2('/work/install/bin/openFPGALoader', program)
shutil.copytree('/work/install/share/openFPGALoader', tools / 'share/openFPGALoader', symlinks=False)
shutil.copy2(src / 'LICENSE', licenses / 'openFPGALoader.txt')

esp = Path('/work/esptool-linux-amd64')
shutil.copy2(esp / 'esptool', tools / 'esptool')
shutil.copy2(esp / 'LICENSE', licenses / 'esptool.txt')

embedded = CArchiveReader(str(esp / 'esptool'))
embedded_notices = []
for name in embedded.toc:
    if any(part in name.lower() for part in ('license', 'copying', 'copyright', 'notice')):
        destination = licenses / 'esptool-runtime' / name
        if '..' in Path(name).parts or Path(name).is_absolute():
            raise RuntimeError('Invalid embedded notice path')
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(embedded.extract(name))
        embedded_notices.append(name)

system = {'libc.so.6', 'libm.so.6', 'libpthread.so.0', 'libdl.so.2', 'librt.so.1'}
libraries = {}
for name, path in re.findall(r'\s+(\S+) => (/\S+) \(',
        subprocess.check_output(['ldd', str(program)], text=True)):
    if name not in system:
        libraries[name] = Path(path)
records = []
source_packages = set()
for name, original in sorted(libraries.items()):
    destination = tools / 'lib' / name
    shutil.copy2(original.resolve(), destination)
    subprocess.run(['patchelf', '--force-rpath', '--set-rpath', '$ORIGIN', str(destination)], check=True)
    owner = None
    for candidate in (original, original.resolve(), Path('/usr') / original.relative_to('/')):
        result = subprocess.run(['dpkg-query', '-S', str(candidate)], text=True, capture_output=True)
        if result.returncode == 0:
            owner = result.stdout.splitlines()[0].split(': /')[0]
            break
    if owner is None:
        raise RuntimeError('No source package found for ' + str(original))
    package, version, source, source_version = subprocess.check_output(['dpkg-query', '-W',
        '-f=${binary:Package}\t${Version}\t${source:Package}\t${source:Version}', owner], text=True).split('\t')
    records.append({'library': name, 'package': package, 'version': version,
        'source': source, 'source_version': source_version})
    copyright_file = Path('/usr/share/doc') / package.split(':')[0] / 'copyright'
    shutil.copy2(copyright_file, licenses / (package.replace(':', '-') + '.txt'))
    source_packages.add((source, source_version))
subprocess.run(['patchelf', '--force-rpath', '--set-rpath', '$ORIGIN/../lib', str(program)], check=True)
shutil.copytree('/usr/share/common-licenses', licenses / 'common', symlinks=False)
wrapper = tools / 'openFPGALoader'
wrapper.write_text('''#!/bin/sh
set -eu
tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export OPENFPGALOADER_SOJ_DIR="$tool_dir/share/openFPGALoader"
exec "$tool_dir/bin/openFPGALoader" "$@"
''')
wrapper.chmod(0o755)

for source, version in sorted(source_packages):
    subprocess.run(['apt-get', 'source', '--only-source', '--download-only', f'{source}={version}'], cwd=sources, check=True)
shutil.copytree('/recipe', sources / 'packaging-recipe')
manifest = {'schema_version': 1, 'portable_tools': True,
    'tools': {'esptool': ['tools/esptool'], 'openFPGALoader': ['tools/openFPGALoader']},
    'versions': {name: inputs[name] for name in ('esptool', 'openFPGALoader')},
    'libraries': records, 'embedded_esptool_notices': embedded_notices}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(licenses / 'README.txt').write_text(
    'esptool is the unmodified Espressif 4.12.0 standalone executable (GPL-2.0-or-later).\n'
    'openFPGALoader is built without source changes from revision ' + inputs['openFPGALoader']['revision'] +
    ' (Apache-2.0). ELF library search paths were adjusted for this relocatable bundle.\n'
    'USB and C++ library notices and exact package versions accompany the bundle.\n'
    'Corresponding source archives and the build recipe are provided in the release asset '
    'ChroMagician-linux-tools-sources.tar.gz. Firmware images are downloaded separately.\n')
subprocess.run([str(tools / 'esptool'), 'version'], check=True)
subprocess.run([str(wrapper), '-V'], check=True)
