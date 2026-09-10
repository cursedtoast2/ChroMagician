import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(*args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--version', help='Override version only for package integration fixtures')
    args = parser.parse_args()
    bundle = Path(args.bundle).resolve()
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=True)
    version = args.version or json.loads((bundle / 'data/flutter_assets/version.json').read_text())['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version):
        raise ValueError('Invalid release version')
    native_version = version.replace('-', '~', 1)
    for file in ['chromatic_pc_backup', 'libexec/chromatic-backup', 'libexec/chromagician-update',
                 'firmware/manifest.json', 'data/app_icon.png', 'LICENSE']:
        if not (bundle / file).is_file():
            raise ValueError('Incomplete app bundle: ' + file)
    if (bundle / 'chromatic_pc_backup').read_bytes()[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Not a Linux x64 app')
    with tempfile.TemporaryDirectory(prefix='chromagician-packages-') as temporary:
        work = Path(temporary)
        root = work / 'root'
        payload = root / 'usr/lib/chromagician'
        shutil.copytree(bundle, payload)
        if args.version:
            (payload / 'data/flutter_assets/version.json').write_text(json.dumps({'version': version}) + '\n')
        for folder in ['usr/bin', 'usr/share/applications', 'usr/share/doc/chromagician']:
            (root / folder).mkdir(parents=True, exist_ok=True)
        launcher = root / 'usr/bin/chromagician'
        launcher.write_text('#!/bin/sh\nexec /usr/lib/chromagician/chromatic_pc_backup "$@"\n')
        launcher.chmod(0o755)
        desktop = root / 'usr/share/applications/org.chromagic.ChroMagician.desktop'
        desktop.write_text('''[Desktop Entry]
Type=Application
Name=ChroMagician
Comment=Back up cartridges and manage your Chromatic
Exec=chromagician
TryExec=chromagician
Icon=org.chromagic.ChroMagician
Terminal=false
Categories=Utility;Game;
StartupWMClass=dev.chromatic.chromatic_pc_backup
''')
        run('desktop-file-validate', str(desktop))
        icons = root / 'usr/share/icons/hicolor/256x256/apps'
        icons.mkdir(parents=True)
        shutil.copy2(bundle / 'data/app_icon.png', icons / 'org.chromagic.ChroMagician.png')
        shutil.copy2(bundle / 'LICENSE', root / 'usr/share/doc/chromagician/copyright')
        (payload / '.linux-package').write_text('deb\n')
        control = root / 'DEBIAN'
        control.mkdir()
        size = sum(p.stat().st_size for p in root.rglob('*') if p.is_file()) // 1024
        (control / 'control').write_text(f'''Package: chromagician
Version: {native_version}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: CursedToast <314077607+cursedtoast2@users.noreply.github.com>
Installed-Size: {size}
Depends: libc6 (>= 2.35), libglib2.0-0 (>= 2.72), libgtk-3-0, libstdc++6, libgl1, libegl1, libgles2, libudev1, policykit-1 | pkexec
Homepage: https://chromagic.org
Description: Desktop companion for ChroMagic
 Back up cartridges and saves, write homebrew, and manage the Chromatic SD card.
 Flashing tools and their runtimes are included.
''')
        deb = out / f'ChroMagician-{version}-linux-x64.deb'
        run('dpkg-deb', '--root-owner-group', '-Zxz', '--build', str(root), str(deb))
        shutil.rmtree(control)
        (payload / '.linux-package').write_text('rpm\n')
        top = work / 'rpm'
        for folder in ['BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS']:
            (top / folder).mkdir(parents=True)
        spec = top / 'SPECS/chromagician.spec'
        spec.write_text(f'''%global _build_id_links none
%global debug_package %{{nil}}
%global __os_install_post %{{nil}}
Name: chromagician
Version: {native_version}
Release: 1
Summary: Desktop companion for ChroMagic
License: GPL-3.0-only
URL: https://chromagic.org
BuildArch: x86_64
AutoReqProv: no
Requires: glibc >= 2.35, gtk3, libstdc++, libglvnd-glx, libglvnd-egl, libglvnd-gles, systemd-libs, polkit, dnf

%description
Back up cartridges and saves, write homebrew, and manage the Chromatic SD card.
Flashing tools and their runtimes are included.

%install
mkdir -p %{{buildroot}}
cp -a {root}/usr %{{buildroot}}/

%files
/usr/bin/chromagician
/usr/lib/chromagician
/usr/share/applications/org.chromagic.ChroMagician.desktop
/usr/share/icons/hicolor/256x256/apps/org.chromagic.ChroMagician.png
%doc /usr/share/doc/chromagician
''')
        run('rpmbuild', '--define', f'_topdir {top}', '-bb', str(spec))
        rpms = list((top / 'RPMS').rglob('*.rpm'))
        if len(rpms) != 1:
            raise ValueError('Expected one RPM')
        shutil.copy2(rpms[0], out / f'ChroMagician-{version}-linux-x64.rpm')
    for file in out.glob(f'ChroMagician-{version}-linux-x64.*'):
        if file.suffix not in ['.deb', '.rpm']:
            continue
        with file.open('rb') as stream:
            sha = hashlib.sha256(stream.read()).hexdigest()
        file.with_name(file.name + '.sha256').write_text(f'{sha}  {file.name}\n')
        print(file.name, file.stat().st_size, sha)


if __name__ == '__main__':
    main()
