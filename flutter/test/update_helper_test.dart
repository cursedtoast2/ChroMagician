import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/update_install.dart';

Future<void> waitFor(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  for (final scenario in [
    'success',
    'startup failure',
    'rename failure',
    'close without approval',
  ]) {
    test('native helper: $scenario', () async {
      final root = await Directory.systemTemp.createTemp('update-helper-test-');
      final target = await Directory(p.join(root.path, 'live app')).create();
      final work = await root.createTemp('.chromagician-update-');
      final incoming = await Directory(
        p.join(work.path, 'ChroMagician'),
      ).create();
      final marker = File(p.join(root.path, 'started-pid'));
      final restored = File(p.join(root.path, 'restored'));
      final preference = await File(
        p.join(root.path, 'preferences'),
      ).writeAsString('keep');
      final parent = await Process.start('/bin/sleep', ['60']);
      Process? helper;
      addTearDown(() async {
        parent.kill();
        await parent.exitCode;
        helper?.kill();
        if (helper != null) await helper.exitCode;
        if (await marker.exists()) {
          final ownedPid = int.tryParse((await marker.readAsString()).trim());
          if (ownedPid != null) Process.killPid(ownedPid);
        }
        await root.delete(recursive: true);
      });
      for (final pair in [(target, '1.0.0'), (incoming, '1.0.1')]) {
        final f = File(
          p.join(pair.$1.path, 'data/flutter_assets/version.json'),
        );
        await f.create(recursive: true);
        await f.writeAsString(jsonEncode({'version': pair.$2}));
      }
      final old = File(p.join(target.path, appExecutable));
      await old.writeAsString(
        '#!/bin/sh\nprintf restored > "${restored.path}"\n',
      );
      await Process.run('chmod', ['755', old.path]);
      final fresh = File(p.join(incoming.path, appExecutable));
      await fresh.writeAsString(
        scenario == 'startup failure'
            ? '#!/bin/sh\nexit 1\n'
            : '#!/bin/sh\nprintf \'{"version":"1.0.1","pid":%s}\' "\$\$" > "\$CHROMAGIC_UPDATE_ACK"\nprintf %s "\$\$" > "${marker.path}"\nexec /bin/sleep 60\n',
      );
      await Process.run('chmod', ['755', fresh.path]);
      final plan = await File(p.join(work.path, 'plan.json')).writeAsString(
        jsonEncode({
          'target': target.path,
          'version': '1.0.1',
          'pid': parent.pid,
          'identity': await linuxProcessIdentity(parent.pid),
        }),
      );
      final native = Platform.environment['CHROMAGIC_TEST_UPDATE_HELPER'];
      helper = await Process.start(
        native ?? 'dart',
        native == null
            ? ['run', 'tool/app_update_helper.dart', plan.path]
            : [plan.path],
      );
      final stdout = helper.stdout.drain<void>();
      final stderr = helper.stderr.drain<void>();
      await waitFor(File(p.join(work.path, 'ready')));
      expect(await bundleVersion(target), '1.0.0');
      if (scenario != 'close without approval') {
        await File(p.join(work.path, 'go')).writeAsString('go');
        await waitFor(File(p.join(work.path, 'accepted')));
        expect(
          await bundleVersion(target),
          '1.0.0',
          reason: 'Must wait for the running app to exit.',
        );
      }
      if (scenario == 'rename failure') await incoming.delete(recursive: true);
      parent.kill();
      await parent.exitCode;
      final code = await helper.exitCode.timeout(const Duration(seconds: 15));
      await stdout;
      await stderr;
      expect(await preference.readAsString(), 'keep');
      if (scenario == 'success') {
        expect(code, 0);
        expect(await bundleVersion(target), '1.0.1');
        expect(await work.exists(), false);
        expect(await marker.exists(), true);
      } else {
        expect(await bundleVersion(target), '1.0.0');
        if (scenario != 'close without approval') {
          expect(code, 1);
          await waitFor(restored);
        }
      }
    }, skip: !Platform.isLinux);
  }
}
