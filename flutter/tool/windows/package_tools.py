import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import zipfile

from PyInstaller.archive.readers import CArchiveReader


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


inputs = json.loads(Path('/out/inputs.json').read_text())
out = Path('/out/firmware')
tools = out / 'tools'
licenses = out / 'licenses'
sources = Path('/out/sources')
work = Path('/work')
for folder in (tools, licenses, sources, work):
    folder.mkdir(parents=True, exist_ok=True)
for name, data in inputs.items():
    archive = Path('/downloads') / name
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == data['sha256']
    if name == 'esptool':
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(work)
    else:
        with tarfile.open(archive) as tf:
            tf.extractall(work, filter='data')
        suffix = '.tar.bz2' if name == 'libusb' else '.tar.gz'
        shutil.copy2(archive, sources / (name + suffix))

usb = work / ('libusb-' + inputs['libusb']['version'])
run(str(usb / 'configure'), '--host=x86_64-w64-mingw32', '--prefix=/work/deps',
    '--enable-shared', '--disable-static', '--disable-udev', cwd=usb)
run('make', '-j2', cwd=usb)
run('make', 'install', cwd=usb)
src = work / ('openFPGALoader-' + inputs['openFPGALoader']['revision'])
env = dict(os.environ, PKG_CONFIG_LIBDIR='/work/deps/lib/pkgconfig')
run('cmake', '-S', str(src), '-B', '/work/build',
    '-DCMAKE_SYSTEM_NAME=Windows', '-DCMAKE_SYSTEM_PROCESSOR=x86_64',
    '-DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc',
    '-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++',
    '-DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres',
    '-DCMAKE_FIND_ROOT_PATH=/work/deps;/usr/x86_64-w64-mingw32',
    '-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY', '-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY',
    '-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY',
    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_INSTALL_PREFIX=/work/install',
    '-DWINDOWS_CROSSCOMPILE=ON', '-DCROSS_COMPILE_DEPS=OFF',
    '-DZLIB_LIBRARY=/usr/x86_64-w64-mingw32/lib/libz.a',
    '-DCMAKE_EXE_LINKER_FLAGS=-static-libgcc -static-libstdc++',
    '-DENABLE_CABLE_ALL=OFF', '-DENABLE_GOWIN_GWU2X=ON', '-DENABLE_USB_SCAN=ON',
    '-DENABLE_VENDORS_ALL=OFF', '-DENABLE_GOWIN_SUPPORT=ON', env=env)
run('cmake', '--build', '/work/build', '--parallel', '2')
run('cmake', '--install', '/work/build')
shutil.copy2('/work/install/bin/openFPGALoader.exe', tools / 'openFPGALoader.exe')
shutil.copy2('/work/deps/bin/libusb-1.0.dll', tools / 'libusb-1.0.dll')
run('x86_64-w64-mingw32-strip', str(tools / 'openFPGALoader.exe'), str(tools / 'libusb-1.0.dll'))
shutil.copy2(src / 'LICENSE', licenses / 'openFPGALoader.txt')
shutil.copy2(usb / 'COPYING', licenses / 'libusb.txt')

esp = work / 'esptool-windows-amd64'
shutil.copy2(esp / 'esptool.exe', tools / 'esptool.exe')
shutil.copy2(esp / 'LICENSE', licenses / 'esptool.txt')
embedded = CArchiveReader(str(esp / 'esptool.exe'))
for name in embedded.toc:
    if any(part in name.lower() for part in ('license', 'copying', 'copyright', 'notice')):
        relative = Path(name.replace('\\', '/'))
        if '..' in relative.parts or relative.is_absolute() or ':' in name:
            raise RuntimeError('Invalid embedded notice path')
        destination = licenses / 'esptool-runtime' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(embedded.extract(name))

system = {'kernel32.dll', 'msvcrt.dll', 'ws2_32.dll', 'advapi32.dll', 'setupapi.dll',
          'user32.dll', 'shell32.dll', 'ole32.dll', 'cfgmgr32.dll', 'bcrypt.dll'}
imports = {}
for binary in sorted(tools.iterdir()):
    details = subprocess.check_output(['x86_64-w64-mingw32-objdump', '-p', str(binary)], text=True)
    if 'pei-x86-64' not in details:
        raise RuntimeError('Expected x64 Windows binary: ' + binary.name)
    dependencies = re.findall(r'DLL Name: (\S+)', details)
    missing = {d.lower() for d in dependencies} - system - {'libusb-1.0.dll'}
    if missing:
        raise RuntimeError(f'Unbundled dependencies in {binary.name}: {missing}')
    imports[binary.name] = dependencies

packages = ['gcc-mingw-w64-x86-64-win32-runtime', 'mingw-w64-common', 'libz-mingw-w64-dev']
records = []
for package in packages:
    version, source, source_version = subprocess.check_output(['dpkg-query', '-W',
        '-f=${Version}\t${source:Package}\t${source:Version}', package], text=True).split('\t')
    records.append({'package': package, 'version': version, 'source': source, 'source_version': source_version})
    shutil.copy2(Path('/usr/share/doc') / package / 'copyright', licenses / (package + '.txt'))
    run('apt-get', 'source', '--only-source', '--download-only', f'{source}={source_version}', cwd=sources)
shutil.copytree('/usr/share/common-licenses', licenses / 'common', symlinks=False)
recipe = sources / 'packaging-recipe/tool'
shutil.copytree('/recipe/windows', recipe / 'windows')
(recipe / 'linux').mkdir()
shutil.copy2('/recipe/linux/inputs.json', recipe / 'linux/inputs.json')
shutil.copy2('/recipe/package_windows_tools.py', recipe / 'package_windows_tools.py')
shutil.copy2('/out/inputs.json', sources / 'inputs.json')
(sources / 'README.txt').write_text(
    'Exact sources and packaging recipe for the Windows flashing tools.\n'
    'Build with: python3 packaging-recipe/tool/package_windows_tools.py --output ./firmware\n'
    'Requires Linux and rootless Podman (or --engine docker).\n'
    'libusb is dynamically linked and can be replaced in firmware/tools/libusb-1.0.dll.\n')
(licenses / 'README.txt').write_text(
    'esptool is the unmodified Espressif 4.12.0 Windows standalone executable.\n'
    'Its Python interpreter and dependencies are embedded; no Python installation is required.\n'
    'openFPGALoader 1.1.1 is built from unmodified source with Gowin/GWU2X and USB discovery enabled.\n'
    'libusb 1.0.27 is dynamically linked. Compiler runtimes and zlib are linked statically.\n'
    'Notices, exact versions, and sources accompany this release. Sources are in\n'
    'ChroMagician-windows-tools-sources.tar.gz. Console firmware is downloaded separately.\n')
(out / 'manifest.json').write_text(json.dumps({'schema_version': 1, 'portable_tools': True,
    'tools': {'esptool': ['tools/esptool.exe'], 'openFPGALoader': ['tools/openFPGALoader.exe']},
    'versions': {k: inputs[k] for k in ('esptool', 'openFPGALoader', 'libusb')},
    'libraries': records, 'pe_imports': imports}, indent=2) + '\n')
