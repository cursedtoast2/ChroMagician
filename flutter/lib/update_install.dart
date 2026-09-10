import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'update_process.dart';
export 'update_process.dart'
    show linuxProcessIdentity, processIdentity, stopUpdateProcess;

String get appExecutable =>
    Platform.isWindows ? 'chromatic_pc_backup.exe' : 'chromatic_pc_backup';
String get updateHelper =>
    Platform.isWindows ? 'chromagician-update.exe' : 'chromagician-update';

Future<String> bundleVersion(Directory bundle) async =>
    (jsonDecode(
              await File(
                p.join(bundle.path, 'data/flutter_assets/version.json'),
              ).readAsString(),
            )
            as Map)['version']
        as String;

Future<void> acknowledgeAppUpdate() async {
  if (!Platform.isLinux && !Platform.isWindows) return;
  final path = Platform.environment['CHROMAGIC_UPDATE_ACK'];
  final bundle = File(Platform.resolvedExecutable).parent;
  if (path != null) {
    final ack = File(path);
    if (p.basename(path) == 'started.json' &&
        p.basename(ack.parent.path).startsWith('.chromagician-update-') &&
        p.equals(p.dirname(ack.parent.path), bundle.parent.path)) {
      await ack.writeAsString(
        jsonEncode({'version': await bundleVersion(bundle), 'pid': pid}),
        flush: true,
      );
    }
  }
  if (Platform.isWindows) {
    unawaited(
      cleanupCompletedUpdates(
        bundle,
        pending: Platform.environment['CHROMAGIC_UPDATE_WORK'],
      ),
    );
  }
}

Future<void> cleanupCompletedUpdates(
  Directory target, {
  String? pending,
}) async {
  try {
    final canonical = await target.resolveSymbolicLinks();
    final parent = Directory(p.dirname(canonical));
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    do {
      var waiting = false;
      await for (final entry in parent.list(followLinks: false)) {
        if (entry is! Directory ||
            !p.basename(entry.path).startsWith('.chromagician-update-')) {
          continue;
        }
        if (!p.equals(await entry.resolveSymbolicLinks(), entry.path)) continue;
        final marker = File(p.join(entry.path, 'completed.json'));
        if (!await marker.exists()) {
          waiting |= pending != null && p.equals(entry.path, pending);
          continue;
        }
        final data = jsonDecode(await marker.readAsString()) as Map;
        if (!p.equals(data['target'] as String, canonical)) continue;
        if (await processIdentity(data['pid'] as int) == data['identity']) {
          waiting = true;
          continue;
        }
        try {
          await entry.delete(recursive: true);
        } on FileSystemException {
          waiting = true;
        }
      }
      if (!waiting) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } while (DateTime.now().isBefore(deadline));
  } on Object {
  }
}

Future<void> renameUpdateDirectory(Directory source, String destination) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    try {
      await source.rename(destination);
      return;
    } on FileSystemException catch (error) {
      if (!Platform.isWindows ||
          ![5, 32, 33].contains(error.osError?.errorCode) ||
          DateTime.now().isAfter(deadline)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

Future<void> updateWindowsInstalledVersion(
  Directory target,
  String version,
) async {
  if (!Platform.isWindows) return;
  try {
    await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ChroMagician_is1'; "
            r'$entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue; '
            r"if ($entry -and $entry.InstallLocation.TrimEnd('\') -ieq $env:CHROMAGIC_INSTALL_ROOT) { "
            r'Set-ItemProperty -LiteralPath $key -Name DisplayVersion -Value $env:CHROMAGIC_INSTALL_VERSION }',
      ],
      environment: {
        'CHROMAGIC_INSTALL_ROOT': target.parent.path,
        'CHROMAGIC_INSTALL_VERSION': version,
      },
    );
  } on ProcessException {
  }
}

Future<void> installUpdate(File planFile) async {
  final plan =
      jsonDecode(await planFile.readAsString()) as Map<String, dynamic>;
  final work = planFile.parent;
  final target = Directory(plan['target'] as String);
  final incoming = Directory(p.join(work.path, 'ChroMagician'));
  final previous = Directory(p.join(work.path, 'previous'));
  if ((!Platform.isLinux && !Platform.isWindows) ||
      plan['identity'] is! String ||
      !p.basename(work.path).startsWith('.chromagician-update-') ||
      !p.equals(await work.parent.resolveSymbolicLinks(), target.parent.path) ||
      !p.equals(await work.resolveSymbolicLinks(), work.path) ||
      !p.equals(await target.resolveSymbolicLinks(), target.path) ||
      await bundleVersion(incoming) != plan['version']) {
    throw const FormatException('Invalid update installation.');
  }
  final lock = await File(
    p.join(target.parent.path, '.${p.basename(target.path)}.update.lock'),
  ).open(mode: FileMode.append);
  var movedOld = false;
  var movedNew = false;
  var committed = false;
  var handedOff = false;
  int? childPid;
  String? childIdentity;
  try {
    await lock.lock(FileLock.exclusive);
    await File(p.join(work.path, 'ready')).writeAsString('ready', flush: true);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      if (await File(p.join(work.path, 'cancel')).exists()) return;
      if (await File(p.join(work.path, 'go')).exists()) {
        await File(
          p.join(work.path, 'accepted'),
        ).writeAsString('accepted', flush: true);
      }
      final exited =
          await processIdentity(plan['pid'] as int) != plan['identity'];
      if (exited) {
        if (!await File(p.join(work.path, 'go')).exists()) return;
        handedOff = true;
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const FileSystemException('The application did not close.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await renameUpdateDirectory(target, previous.path);
    movedOld = true;
    await renameUpdateDirectory(incoming, target.path);
    movedNew = true;
    final environment = Map<String, String>.from(Platform.environment)
      ..remove('CHROMAGIC_UPDATE_FAILED')
      ..['CHROMAGIC_UPDATE_WORK'] = work.path
      ..['CHROMAGIC_UPDATE_ACK'] = p.join(work.path, 'started.json');
    final child = await Process.start(
      p.join(target.path, appExecutable),
      [],
      workingDirectory: target.path,
      environment: environment,
      mode: ProcessStartMode.detached,
    );
    childPid = child.pid;
    childIdentity = await processIdentity(child.pid);
    final startupDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(startupDeadline)) {
      final ack = File(environment['CHROMAGIC_UPDATE_ACK']!);
      if (await ack.exists()) {
        try {
          final result = jsonDecode(await ack.readAsString()) as Map;
          if (result['version'] == plan['version'] &&
              result['pid'] == childPid) {
            committed = true;
            break;
          }
        } on FormatException {
        }
      }
      if (childIdentity == null ||
          await processIdentity(child.pid) != childIdentity) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!committed) {
      throw const FileSystemException('The updated app could not start.');
    }
    await updateWindowsInstalledVersion(target, plan['version'] as String);
  } on Object {
    if (handedOff && !committed) {
      if (childPid != null && childIdentity != null) {
        await stopUpdateProcess(childPid, childIdentity);
      }
      if (movedOld) {
        if (movedNew) {
          await renameUpdateDirectory(target, p.join(work.path, 'failed'));
        }
        await renameUpdateDirectory(previous, target.path);
      }
      final environment = Map<String, String>.from(Platform.environment)
        ..remove('CHROMAGIC_UPDATE_ACK')
        ..['CHROMAGIC_UPDATE_WORK'] = work.path
        ..['CHROMAGIC_UPDATE_FAILED'] = '1';
      await Process.start(
        p.join(target.path, appExecutable),
        [],
        workingDirectory: target.path,
        environment: environment,
        mode: ProcessStartMode.detached,
      );
    }
    rethrow;
  } finally {
    await lock.close();
    if (committed || !await previous.exists()) {
      try {
        if (Platform.isWindows) {
          final marker = await File(p.join(work.path, 'completed.tmp'))
              .writeAsString(
                jsonEncode({
                  'target': target.path,
                  'pid': pid,
                  'identity': await processIdentity(pid),
                }),
                flush: true,
              );
          await marker.rename(p.join(work.path, 'completed.json'));
        } else if (committed || movedOld) {
          await work.delete(recursive: true);
        }
      } on FileSystemException {
      }
    }
  }
}
