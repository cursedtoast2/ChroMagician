import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'releases.dart';
import 'update_install.dart';
import 'windows_update_archive.dart';

abstract class AppInstaller {
  Future<PreparedAppUpdate> prepare(
    GitHubRelease release,
    void Function(String) status,
  );
}

abstract class PreparedAppUpdate {
  Future<void> restart(Future<void> Function() beforeExit);
  Future<void> discard();
}

class AppUpdater implements AppInstaller {
  AppUpdater(this.client, {Directory? installation, String? platform})
    : installation = installation ?? File(Platform.resolvedExecutable).parent,
      platform =
          platform ??
          switch (Abi.current()) {
            Abi.linuxX64 => 'linux-x64',
            Abi.linuxArm64 => 'linux-arm64',
            Abi.windowsX64 => 'windows-x64',
            _ => 'unsupported',
          };
  final ReleaseClient client;
  final Directory installation;
  final String platform;

  @override
  Future<PreparedAppUpdate> prepare(
    GitHubRelease release,
    void Function(String) status,
  ) async {
    if (!['linux-x64', 'linux-arm64', 'windows-x64'].contains(platform)) {
      throw const ReleaseFailure(
        'Automatic installation is not available for this operating system yet.',
      );
    }
    if (release.repository != appRepository || release.version == null) {
      throw const ReleaseFailure('The app release is invalid.');
    }
    final target = Directory(await installation.resolveSymbolicLinks());
    final windows = platform == 'windows-x64';
    final helperName = windows
        ? 'chromagician-update.exe'
        : 'chromagician-update';
    final helper = File(p.join(target.path, 'libexec', helperName));
    if (!await helper.exists()) {
      throw const ReleaseFailure(
        'The update tools are missing. Reinstall the complete app.',
      );
    }
    final installed = releaseVersion(await bundleVersion(target));
    if (installed == null || release.version! <= installed) {
      throw const ReleaseFailure('This app is already up to date.');
    }
    final packageMarker = File(p.join(target.path, '.linux-package'));
    if (platform.startsWith('linux-') && await packageMarker.exists()) {
      final format = (await packageMarker.readAsString()).trim();
      if (!['deb', 'rpm'].contains(format)) {
        throw const ReleaseFailure('The installed package format is invalid.');
      }
      status('Downloading update...');
      final asset = release.asset(
        'ChroMagician-${release.version}-$platform.$format',
      );
      final download = await client.download(
        release,
        asset,
        maxBytes: 128 * 1024 * 1024,
      );
      final staging = await Directory.systemTemp.createTemp(
        'chromagician-package-',
      );
      try {
        final package = await download.copy(
          p.join(staging.path, 'chromagician.$format'),
        );
        if ((await sha256.bind(package.openRead()).first).toString() !=
            asset.digest) {
          throw const ReleaseFailure('The download did not pass verification.');
        }
        await validateLinuxPackage(
          package,
          format,
          release.version.toString(),
          platform,
        );
        return LinuxPackageUpdate(
          package,
          target,
          release.version.toString(),
          format,
          status,
        );
      } on Object {
        await staging.delete(recursive: true);
        rethrow;
      }
    }
    final asset = release.asset(
      'ChroMagician-${release.version}-$platform.${windows ? 'zip' : 'tar.gz'}',
    );
    Directory work;
    try {
      work = await target.parent.createTemp('.chromagician-update-');
    } on FileSystemException {
      throw const ReleaseFailure(
        'ChroMagician cannot update in this folder. Move the app to a folder you can write to.',
      );
    }
    try {
      status('Downloading update...');
      final download = await client.download(
        release,
        asset,
        maxBytes: 128 * 1024 * 1024,
      );
      status('Preparing update...');
      final downloadPath = download.path;
      final workPath = work.path;
      final expectedVersion = release.version!.toString();
      final expectedPlatform = platform;
      await Isolate.run(
        () => extractAppUpdate(
          downloadPath,
          workPath,
          expectedVersion,
          expectedPlatform,
        ),
      );
      final helperCopy = await helper.copy(p.join(work.path, helperName));
      if (!windows) await executableMode(helperCopy.path, '700');
      return LocalAppUpdate(work, target, expectedVersion);
    } on Object {
      await work.delete(recursive: true);
      rethrow;
    }
  }
}

Future<void> validateLinuxPackage(
  File package,
  String format,
  String version,
  String platform,
) async {
  final query = format == 'deb'
      ? [
          '/usr/bin/dpkg-deb',
          '--show',
          r'--showformat=${Package}\n${Version}\n${Architecture}\n',
          package.path,
        ]
      : [
          '/usr/bin/rpm',
          '-qp',
          '--queryformat',
          '%{NAME}\n%{VERSION}\n%{ARCH}\n',
          package.path,
        ];
  final result = await Process.run(query.first, query.skip(1).toList());
  final expectedArch = platform == 'linux-x64'
      ? (format == 'deb' ? 'amd64' : 'x86_64')
      : (format == 'deb' ? 'arm64' : 'aarch64');
  final expected =
      'chromagician\n${version.replaceFirst('-', '~')}\n$expectedArch';
  if (result.exitCode != 0 || result.stdout.toString().trim() != expected) {
    throw const ReleaseFailure(
      'The update package does not match this release or computer.',
    );
  }
}

class LinuxPackageUpdate implements PreparedAppUpdate {
  LinuxPackageUpdate(
    this.package,
    this.target,
    this.version,
    this.format,
    this.status,
  );
  final File package;
  final Directory target;
  final String version, format;
  final void Function(String) status;

  @override
  Future<void> restart(Future<void> Function() beforeExit) async {
    await beforeExit();
    status('Installing update...');
    final manager = format == 'deb' ? '/usr/bin/apt-get' : '/usr/bin/dnf';
    final process = await Process.start('/usr/bin/pkexec', [
      manager,
      '-y',
      'install',
      '--',
      package.path,
    ]);
    final output = Future.wait([
      process.stdout.drain<void>(),
      process.stderr.drain<void>(),
    ]);
    final result = await process.exitCode;
    await output;
    if (result == 126 || result == 127) {
      throw const ReleaseFailure('The update was not authorized.');
    }
    if (result != 0 || await bundleVersion(target) != version) {
      throw const ReleaseFailure(
        'The system package manager could not install the update.',
      );
    }
    await Process.start(
      p.join(target.path, appExecutable),
      [],
      workingDirectory: target.path,
      mode: ProcessStartMode.detached,
    );
    await discard();
    exit(0);
  }

  @override
  Future<void> discard() async {
    if (p.basename(package.parent.path).startsWith('chromagician-package-') &&
        await package.parent.exists()) {
      await package.parent.delete(recursive: true);
    }
  }
}

Future<void> executableMode(String path, String mode) async {
  if (Platform.isWindows) return;
  if ((await Process.run('chmod', [mode, path])).exitCode != 0) {
    throw const ReleaseFailure('The update could not set file permissions.');
  }
}

Future<void> extractAppUpdate(
  String archivePath,
  String workPath,
  String version,
  String platform,
) async {
  if (platform == 'windows-x64') {
    return extractWindowsUpdate(archivePath, workPath, version);
  }
  const limit = 512 * 1024 * 1024;
  final tar = File(p.join(workPath, 'payload.tar'));
  final sink = tar.openWrite();
  var total = 0;
  try {
    await for (final bytes in File(
      archivePath,
    ).openRead().transform(gzip.decoder)) {
      total += bytes.length;
      if (total > limit) {
        throw const ReleaseFailure('The app update is too large.');
      }
      sink.add(bytes);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  final input = InputFileStream(tar.path);
  try {
    final decoder = TarDecoder();
    final archive = decoder.decodeStream(input);
    final names = <String>{};
    var expanded = 0;
    for (final entry in decoder.files) {
      final name = p.posix.normalize(entry.filename);
      if (!['', '0', '5'].contains(entry.typeFlag) ||
          entry.filename.contains('\\') ||
          entry.filename.contains('\u0000') ||
          entry.filename.split('/').contains('..') ||
          !(name == 'ChroMagician' || p.posix.isWithin('ChroMagician', name)) ||
          !names.add(name)) {
        throw const ReleaseFailure(
          'The app archive contains an invalid path or file.',
        );
      }
    }
    for (final entry in archive) {
      expanded += entry.size;
      if (entry.isSymbolicLink || expanded > limit) {
        throw const ReleaseFailure('The app archive is invalid.');
      }
      final path = p.join(workPath, p.posix.normalize(entry.name));
      if (entry.isDirectory) {
        await Directory(path).create(recursive: true);
      } else {
        await File(path).parent.create(recursive: true);
        final output = OutputFileStream(path);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        if ((entry.mode & 0x49) != 0) await executableMode(path, '755');
      }
    }
  } finally {
    input.closeSync();
    await tar.delete();
  }
  final bundle = Directory(p.join(workPath, 'ChroMagician'));
  if (await bundleVersion(bundle) != version) {
    throw const ReleaseFailure('The app version does not match the release.');
  }
  final machine = platform == 'linux-x64' ? 62 : 183;
  for (final name in [
    'chromatic_pc_backup',
    'libexec/chromagician-update',
    'libexec/chromatic-backup',
    'lib/libflutter_linux_gtk.so',
    'lib/libapp.so',
  ]) {
    final file = await File(p.join(bundle.path, name)).open();
    final bytes = await file.read(20);
    await file.close();
    if (bytes.length < 20 ||
        bytes[0] != 0x7f ||
        utf8.decode(bytes.sublist(1, 4), allowMalformed: true) != 'ELF' ||
        bytes[4] != 2 ||
        bytes[5] != 1 ||
        bytes[18] != machine ||
        bytes[19] != 0) {
      throw const ReleaseFailure('The app update is for a different computer.');
    }
  }
}

class LocalAppUpdate implements PreparedAppUpdate {
  LocalAppUpdate(this.work, this.target, this.version);
  final Directory work, target;
  final String version;
  bool _handedOff = false;
  int? _helperPid;
  String? _helperIdentity;

  @override
  Future<void> restart(Future<void> Function() beforeExit) async {
    final identity = await processIdentity(pid);
    if (identity == null) {
      throw const ReleaseFailure(
        'The updater could not identify the running app.',
      );
    }
    final plan = File(p.join(work.path, 'plan.json'));
    await plan.writeAsString(
      jsonEncode({
        'target': target.path,
        'version': version,
        'pid': pid,
        'identity': identity,
      }),
      flush: true,
    );
    final helper = await Process.start(
      p.join(work.path, updateHelper),
      [plan.path],
      workingDirectory: work.path,
      mode: ProcessStartMode.detached,
    );
    _helperPid = helper.pid;
    _helperIdentity = await processIdentity(helper.pid);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!await File(p.join(work.path, 'ready')).exists()) {
      if (await File(p.join(work.path, 'error')).exists() ||
          DateTime.now().isAfter(deadline)) {
        await File(
          p.join(work.path, 'cancel'),
        ).writeAsString('cancel', flush: true);
        throw const ReleaseFailure(
          'The updater could not start. Please try again.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    try {
      await beforeExit();
      await File(p.join(work.path, 'go')).writeAsString('go', flush: true);
      final acceptedDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (!await File(p.join(work.path, 'accepted')).exists()) {
        if (await File(p.join(work.path, 'error')).exists() ||
            DateTime.now().isAfter(acceptedDeadline)) {
          throw const ReleaseFailure(
            'The updater could not finish preparing. Please try again.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      _handedOff = true;
      exit(0);
    } on Object {
      await File(
        p.join(work.path, 'cancel'),
      ).writeAsString('cancel', flush: true);
      rethrow;
    }
  }

  @override
  Future<void> discard() async {
    if (_handedOff || !await work.exists()) return;
    await File(
      p.join(work.path, 'cancel'),
    ).writeAsString('cancel', flush: true);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_helperPid != null &&
        _helperIdentity != null &&
        await processIdentity(_helperPid!) == _helperIdentity) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (await work.exists()) await work.delete(recursive: true);
  }
}
