import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/update_install.dart';
import 'package:chromatic_pc_backup/app_update.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> waitFor(File marker, {int seconds = 15}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (true) {
    if (await marker.exists() && await marker.length() > 0) return;
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Missing ${marker.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> main(List<String> args) async {
  if (!Platform.isWindows || args.length < 3) {
    throw ArgumentError('Windows: helper.exe fixture.exe locked.dll [app.zip]');
  }
  final helperBinary = File(args[0]).absolute;
  final fixture = File(args[1]).absolute;
  final dll = File(args[2]).absolute;
  for (final scenario
      in args.contains('--flutter-only')
          ? ['Flutter first frame']
          : [
              'success',
              'startup exit',
              'startup hang',
              'rename failure',
              'cancel',
              'close without handoff',
              'production handoff',
              'production cancellation',
              if (args.length >= 4) 'Flutter first frame',
            ]) {
    final temporary = await Directory.systemTemp.createTemp(
      'ChroMagician é & test ',
    );
    final root = Directory(await temporary.resolveSymbolicLinks());
    final target = await Directory(p.join(root.path, 'live app')).create();
    final work = await root.createTemp('.chromagician-update-');
    final incoming = await Directory(
      p.join(work.path, 'ChroMagician'),
    ).create();
    final version = scenario == 'Flutter first frame'
        ? RegExp(r'ChroMagician-(.*)-windows-x64.zip$').firstMatch(args[3])![1]!
        : '1.0.1';
    Process? parent, helper;
    final output = StringBuffer();
    try {
      for (final bundle in [target, incoming]) {
        await File(p.join(bundle.path, 'data/flutter_assets/version.json'))
            .create(recursive: true)
            .then(
              (f) => f.writeAsString(
                jsonEncode({'version': bundle == target ? '1.0.0' : version}),
              ),
            );
        await fixture.copy(p.join(bundle.path, appExecutable));
        await dll.copy(p.join(bundle.path, 'locked.dll'));
        await File(p.join(bundle.path, 'mode')).writeAsString(
          bundle == target
              ? 'ack'
              : scenario == 'startup exit'
              ? 'exit'
              : scenario == 'startup hang'
              ? 'hang'
              : 'ack',
        );
      }
      if (scenario == 'Flutter first frame') {
        await incoming.delete(recursive: true);
        await extractAppUpdate(
          File(args[3]).absolute.path,
          work.path,
          version,
          'windows-x64',
        );
      }
      final preferences = await File(
        p.join(root.path, 'preferences'),
      ).writeAsString('keep');
      final environment = {
        'CHROMAGIC_TEST_ROOT': root.path,
        if (scenario.startsWith('production'))
          'CHROMAGIC_TEST_HANDOFF': work.path,
        if (scenario == 'production cancellation') 'CHROMAGIC_TEST_CANCEL': '1',
        'APPDATA': p.join(root.path, 'profile'),
        'LOCALAPPDATA': p.join(root.path, 'profile'),
      };
      parent = await Process.start(
        p.join(target.path, appExecutable),
        [],
        environment: environment,
      );
      parent.stdout.drain<void>();
      parent.stderr.drain<void>();
      await waitFor(File(p.join(root.path, 'parent.json')));
      final parentIdentity = await processIdentity(parent.pid);
      check(parentIdentity != null, 'Must identify the real Windows process');
      await stopUpdateProcess(parent.pid, 'wrong identity');
      check(
        await processIdentity(parent.pid) == parentIdentity,
        'Never terminate a reused/unrelated PID',
      );
      for (final name in [appExecutable, 'locked.dll']) {
        var locked = false;
        try {
          await File(p.join(target.path, name)).delete();
        } on FileSystemException {
          locked = true;
        }
        check(locked, '$name must be held open by the running Windows process');
      }
      final plan = await File(p.join(work.path, 'plan.json')).writeAsString(
        jsonEncode({
          'target': target.path,
          'version': version,
          'pid': parent.pid,
          'identity': parentIdentity,
        }),
      );
      final copy = await helperBinary.copy(p.join(work.path, updateHelper));
      if (scenario.startsWith('production')) {
        await File(p.join(root.path, 'begin')).writeAsString('begin');
        final canceled = scenario == 'production cancellation';
        await waitFor(
          File(p.join(root.path, canceled ? 'canceled' : 'updated.json')),
        );
        if (!canceled) await parent.exitCode;
        check(
          await File(p.join(root.path, 'released')).exists(),
          'beforeExit callback was not invoked',
        );
        check(
          await bundleVersion(target) == (canceled ? '1.0.0' : '1.0.1'),
          'Production handoff installed wrong version',
        );
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (await work.exists() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        check(
          !await work.exists(),
          'Production handoff/discard left running helper or staging',
        );
        check(
          await preferences.readAsString() == 'keep',
          'Preferences changed',
        );
        stdout.writeln(
          'PASS Windows: $scenario (production restart/discard, EXE/DLL locks, cleanup)',
        );
        continue;
      }
      helper = await Process.start(
        copy.path,
        [plan.path],
        workingDirectory: work.path,
        environment: environment,
      );
      helper.stdout.transform(utf8.decoder).listen(output.write);
      helper.stderr.transform(utf8.decoder).listen(output.write);
      await waitFor(File(p.join(work.path, 'ready')));
      if (scenario == 'cancel') {
        await File(p.join(work.path, 'cancel')).writeAsString('cancel');
      } else if (scenario != 'close without handoff') {
        await File(p.join(work.path, 'go')).writeAsString('go');
        await waitFor(File(p.join(work.path, 'accepted')));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        check(
          await bundleVersion(target) == '1.0.0',
          'Must not replace until parent exits',
        );
      }
      if (scenario == 'rename failure') await incoming.delete(recursive: true);
      if (scenario != 'cancel') {
        await stopUpdateProcess(parent.pid, parentIdentity!);
        await parent.exitCode;
      }
      final code = await helper.exitCode.timeout(const Duration(seconds: 55));
      final success =
          scenario == 'success' || scenario == 'Flutter first frame';
      check(
        await bundleVersion(target) == (success ? version : '1.0.0'),
        'Wrong installed version: $scenario ($code) $output',
      );
      check(await preferences.readAsString() == 'keep', 'Preferences changed');
      if (success) {
        check(code == 0, 'Updated app did not acknowledge startup: $output');
        if (scenario != 'Flutter first frame') {
          await waitFor(File(p.join(root.path, 'updated.json')));
        }
      } else if (!['cancel', 'close without handoff'].contains(scenario)) {
        check(code == 1, 'Failure must report rollback');
        await waitFor(File(p.join(root.path, 'restored.json')));
      } else {
        check(code == 0, 'Cancellation failed');
        check(
          !await File(p.join(root.path, 'restored.json')).exists(),
          'Cancellation must not restart app',
        );
      }
      await cleanupCompletedUpdates(target);
      final cleanupDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (await work.exists() && DateTime.now().isBefore(cleanupDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await cleanupCompletedUpdates(target);
      }
      check(!await work.exists(), 'Completed staging/helper was not removed');
      stdout.writeln(
        'PASS Windows: $scenario (EXE/DLL locks, version, preferences, cleanup)',
      );
    } catch (error, stack) {
      stderr.writeln('FAIL Windows $scenario: $error\n$stack\n$output');
      rethrow;
    } finally {
      if (helper != null) {
        helper.kill();
        await helper.exitCode;
      }
      if (parent != null) {
        parent.kill();
        await parent.exitCode;
      }
      for (final role in ['parent', 'updated', 'restored']) {
        final marker = File(p.join(root.path, '$role.json'));
        if (await marker.exists()) {
          final data = jsonDecode(await marker.readAsString()) as Map;
          if (data['identity'] != null) {
            await stopUpdateProcess(
              data['pid'] as int,
              data['identity'] as String,
            );
          }
        }
      }
      if (scenario == 'Flutter first frame') {
        await Process.run(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'Get-Process -Name chromatic_pc_backup -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $env:CHROMAGIC_TEST_EXE } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; Wait-Process -Id $_.Id -ErrorAction SilentlyContinue }',
          ],
          environment: {
            'CHROMAGIC_TEST_EXE': p.join(target.path, appExecutable),
          },
        );
      }
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        stderr.writeln('Retained diagnostics: ${root.path}\n$output');
      }
    }
  }
}
