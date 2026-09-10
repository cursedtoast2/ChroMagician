import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/backend.dart';

void main() {
  group('firmware query process deadline', () {
    late Directory directory;
    late String executable;

    setUpAll(() async {
      directory = await Directory.systemTemp.createTemp('firmware deadline ');
      addTearDown(() => directory.delete(recursive: true));
      executable = '${directory.path}/probe${Platform.isWindows ? '.exe' : ''}';
      final result = await Process.run('dart', [
        'compile',
        'exe',
        'test/support/backend_timeout_fixture.dart',
        '-o',
        executable,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    for (final mode in ['silent', 'chatter', 'complete-but-alive']) {
      test('terminates a $mode helper and permits another query', () async {
        final backend = ProcessBackend(
          executable,
          firmwareInfoTimeout: const Duration(seconds: 2),
        );
        final events = <BackendEvent>[];
        final elapsed = Stopwatch()..start();
        await expectLater(
          backend
              .run(['--firmware-info', '--after-flash', '--port', mode])
              .forEach(events.add),
          throwsA(
            isA<BackendFailure>().having(
              (error) => error.code,
              'code',
              'firmware_timeout',
            ),
          ),
        );
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 5)));
        expect(events.where((event) => event['event'] == 'complete'), isEmpty);
        final port = events.first['port'] as int;
        final released = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await released.close();
        expect(await backend.firmwareInfo('success', afterFlash: true), {
          'mcu': 'v0.13.4',
          'fpga': '18.8',
          'chromatic': 'v4.2',
        });
      });
    }

    test(
      'does not terminate cartridge operations at the probe deadline',
      () async {
        final backend = ProcessBackend(
          executable,
          firmwareInfoTimeout: const Duration(milliseconds: 250),
        );
        final events = await backend.run([
          '--port',
          'transfer',
          '--rom',
          'game.gb',
        ]).toList();
        expect(events.last['event'], 'complete');
      },
    );
  });

  test(
    'missing cartridge tools do not expose process commands or paths',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'missing-backend',
      );
      addTearDown(() => directory.delete(recursive: true));
      final backend = ProcessBackend('${directory.path}/missing executable');
      final expected = isA<BackendFailure>().having(
        (error) => error.message,
        'message',
        'The cartridge tools could not start. Restart ChroMagician.',
      );
      await expectLater(backend.devices(), throwsA(expected));
      await expectLater(backend.watch('/dev/test').toList(), throwsA(expected));
      await expectLater(backend.run([]).toList(), throwsA(expected));
    },
  );

  Future<ProcessBackend> fixture(String body) async {
    final directory = await Directory.systemTemp.createTemp(
      'chromatic backend test ',
    );
    addTearDown(() => directory.delete(recursive: true));
    final script = File('${directory.path}/backend with spaces');
    await script.writeAsString(
      '#!/usr/bin/env python3\nimport sys, json\n$body\n',
    );
    await Process.run('chmod', ['+x', script.path]);
    return ProcessBackend(script.path);
  }

  test('drains stderr and preserves argument boundaries', () async {
    final backend = await fixture('''
sys.stderr.write('x' * 200000)
print(json.dumps({'event':'arguments', 'args':sys.argv[1:]}))
print('{"event":"complete"}')
''');
    final events = await backend.run([
      '--rom',
      '/tmp/a game with spaces.gb',
    ]).toList();
    expect(events.first['args'], [
      '--rom',
      '/tmp/a game with spaces.gb',
      '--json',
    ]);
    expect(events.last['event'], 'complete');
  }, skip: Platform.isWindows);

  test(
    'discovery exits before a transfer and can resume afterward',
    () async {
      final backend = await fixture('''
import pathlib, time
lock = pathlib.Path(__file__).with_suffix('.watching')
if '--watch' in sys.argv:
    lock.write_text('open')
    print('{"event":"session_started","schema_version":1}', flush=True)
    print('{"event":"cartridge_unavailable"}', flush=True)
    sys.stdin.read()
    time.sleep(0.05)
    lock.unlink()
    print('{"event":"complete","operation":"watch"}', flush=True)
else:
    if lock.exists():
        sys.exit(7)
    print('{"event":"complete"}')
''');
      for (var i = 0; i < 2; i++) {
        final ready = Completer<void>();
        final done = backend.watch('/dev/test with spaces').forEach((event) {
          if (event['event'] == 'cartridge_unavailable') ready.complete();
        });
        await ready.future.timeout(const Duration(seconds: 5));
        final events = await backend.run(['--rom', '/tmp/game.gb']).toList();
        await done;
        expect(events.single['event'], 'complete');
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'complete followed by failed exit never becomes success',
    () async {
      final backend = await fixture('''
print(json.dumps({'event':'complete'}))
sys.exit(1)
''');
      final seen = <BackendEvent>[];
      await expectLater(
        backend.run([]).forEach(seen.add),
        throwsA(isA<BackendFailure>()),
      );
      expect(seen.where((event) => event['event'] == 'complete'), isEmpty);
    },
    skip: Platform.isWindows,
  );

  test(
    'truncated, malformed and unsupported protocol responses fail',
    () async {
      for (final body in [
        'print(json.dumps({"event":"progress", "completed":1,"total":1}))',
        'print("not json")\nprint(json.dumps({"event":"complete"}))',
        'print(json.dumps({"event":"session_started", "schema_version":2}))\nprint(json.dumps({"event":"complete"}))',
      ]) {
        final backend = await fixture(body);
        await expectLater(
          backend.run([]).toList(),
          throwsA(isA<BackendFailure>()),
        );
      }
    },
    skip: Platform.isWindows,
  );
}
