import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


def run(*command, **kwargs):
    subprocess.run(command, check=True, **kwargs)


def validate_bundle_paths(bundle):
    for file in bundle.rglob('*'):
        if not file.is_file():
            continue
        data = file.read_bytes()
        if re.search(rb'/(?:home|Users)/[^/\x00\n]+/', data):
            raise ValueError(f'Home directory embedded in {file.relative_to(bundle)}; '
                             'build the release outside a user home directory')
        if not data.startswith(b'\x7fELF'):
            continue
        dynamic = subprocess.check_output(['readelf', '-d', str(file)], text=True)
        for paths in re.findall(r'\((?:RUNPATH|RPATH)\).*?\[(.*?)\]', dynamic):
            if any(path not in ('$ORIGIN', '${ORIGIN}') and
                   not path.startswith(('$ORIGIN/', '${ORIGIN}/',
                                        '/usr/lib/', '/usr/lib64/', '/lib/', '/lib64/'))
                   for path in paths.split(':')):
                raise ValueError(f'Build directory in library search path for {file.relative_to(bundle)}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', default='build/linux/x64/release/bundle')
    parser.add_argument('--output', default='build/linux-package')
    parser.add_argument('--engine', choices=['podman', 'docker'],
                        default=os.environ.get('CHROMAGIC_CONTAINER_ENGINE', 'podman'))
    args = parser.parse_args()
    app = Path(__file__).resolve().parent.parent
    bundle = (app / args.bundle).resolve()
    output = (app / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if output.is_relative_to(bundle):
        raise ValueError('Output must be outside the application bundle')
    validate_bundle_paths(bundle)
    version = json.loads((bundle / 'data/flutter_assets/version.json').read_text())['version']
    source_archive = app / '.dart_tool/ChroMagician-linux-tools-sources.tar.gz'
    if not source_archive.is_file():
        raise ValueError('Build the bundled flashing tools before packaging')
    with tempfile.TemporaryDirectory(prefix='linux-release-', dir=app / '.dart_tool') as temporary:
        work = Path(temporary)
        payload = work / 'bundle'
        shutil.copytree(bundle, payload)
        shutil.copy2(app.parent / 'LICENSE', payload / 'LICENSE')
        driver = work / 'update-driver'
        run('dart', 'compile', 'exe', 'test/support/installed_update_driver.dart', '-o', str(driver), cwd=app)
        images = {
            'packages': ('tool/linux/packages.Containerfile', 'localhost/chromagician-native-packager:22.04'),
            'deb': ('test/linux-native-ubuntu.Containerfile', 'localhost/chromagician-native-ubuntu:22.04'),
            'rpm': ('test/linux-native-fedora.Containerfile', 'localhost/chromagician-native-fedora:44'),
        }
        build_limits = ['--cpu-period', '100000', '--cpu-quota', '200000', '--memory', '3g'] if args.engine == 'podman' else []
        for recipe, image in images.values():
            run(args.engine, 'build', *build_limits,
                '-f', str(app / recipe), '-t', image, str((app / recipe).parent))
        container = [args.engine, 'run', '--rm', '--cpus', '2', '--memory', '3g', '--security-opt', 'label=disable']
        identity = ['--user', f'{os.getuid()}:{os.getgid()}'] if args.engine == 'docker' else []
        fixtures = work / 'fixtures'
        fixtures.mkdir()
        for destination, override in [(output, []), (fixtures, ['--version', '0.0.1'])]:
            run(*container, *identity, '-v', f'{payload}:/bundle:ro', '-v', f'{app / "tool/linux"}:/recipe:ro',
                '-v', f'{destination}:/out:rw', images['packages'][1], 'python3', '/recipe/build_packages.py',
                '--bundle', '/bundle', '--output', '/out', *override)
        for format in ['deb', 'rpm']:
            with (output / f'{format}-installer-test.log').open('w') as log:
                run(*container, '-v', f'{output}:/packages:ro', '-v', f'{fixtures}:/fixtures:ro',
                    '-v', f'{app / "test/linux_native_installer_test.py"}:/test.py:ro', '-v', f'{driver}:/driver:ro',
                    images[format][1], 'dbus-run-session', '--', 'xvfb-run', '-a', 'python3', '/test.py',
                    '--format', format, '--base', f'/fixtures/ChroMagician-0.0.1-linux-x64.{format}',
                    '--update', f'/packages/ChroMagician-{version}-linux-x64.{format}', '--version', version,
                    '--driver', '/driver', stdout=log, stderr=subprocess.STDOUT)
            print(f'PASS {format} installer; log: {output / (format + "-installer-test.log")}')
        archive = output / f'ChroMagician-{version}-linux-x64.tar.gz'
        with tarfile.open(archive, 'w:gz', compresslevel=6) as tar:
            tar.add(payload, arcname='ChroMagician')
        sources = output / source_archive.name
        shutil.copy2(source_archive, sources)
        for file in [archive, sources]:
            sha = hashlib.sha256(file.read_bytes()).hexdigest()
            file.with_name(file.name + '.sha256').write_text(f'{sha}  {file.name}\n')
        print('Tested Linux release files:', output)


if __name__ == '__main__':
    main()
