import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/backend.dart';
import 'package:chromatic_pc_backup/firmware.dart';

class FirmwareBackend extends CartBackend {
  List<String> ports = ['COM4'];
  Map<String, String> version = {
    'mcu': 'v0.13.4',
    'fpga': '18.12',
    'chromatic': 'ChroMagic 1.0.0-rc.1 (4.2)',
  };
  final queries = <List<String>>[];
  void Function(List<String>)? onQuery;
  @override
  Future<List<String>> devices() async => ports;
  @override
  Stream<BackendEvent> run(List<String> arguments) async* {
    queries.add(arguments);
    onQuery?.call(arguments);
    yield {'event': 'firmware_info', 'version': version};
    yield {'event': 'complete'};
  }
}

class FakeFirmwareTools implements FirmwareTools {
  final commands = <List<String>>[];
  String? failOn;
  bool mcuChecksum = true;
  bool imageChecksum = true;
  String scan = '003 008 0x33aa:0x0120 gwu2x GOWINSEMI 00010000 GWU2X';
  String detection = 'idcode 0x0001281b\nGW5A-25';
  void Function(List<String>)? onCommand;
  @override
  Future<ToolResult> run(
    List<String> command,
    void Function(String) onLine, {
    Duration? timeout,
  }) async {
    commands.add(command);
    onCommand?.call(command);
    if (failOn != null && command.contains(failOn)) {
      return const ToolResult(1, 'USB disconnected');
    }
    final output = command.contains('--scan-usb')
        ? scan
        : command.contains('--detect')
        ? detection
        : command.contains('image_info')
        ? 'Checksum: 77 (${imageChecksum ? 'valid' : 'invalid'})\nValidation Hash: abc (valid)'
        : command.contains('write_flash')
        ? 'Writing at 0x10000... (50 %)\n${mcuChecksum ? 'Hash of data verified.' : 'Done'}'
        : command.contains('--write-flash')
        ? 'Erasing: [==] 100.00%\nWriting: [==] 50.00%\nVerifying write (May take time)\nReading: [==] 100.00%\nDone'
        : 'version';
    for (final line in output.split('\n')) {
      onLine(line);
    }
    return ToolResult(0, output);
  }
}

Future<FirmwareBundle> fixtureBundle(Directory root) async {
  final releases = <Map<String, Object>>[];
  for (final id in ['chromagician', 'stock']) {
    final mcu = List<int>.filled(256, 0);
    mcu[0] = 0xe9;
    final mcuPackage = id == 'stock'
        ? [...List<int>.filled(0x10000, 0xff), ...mcu]
        : mcu;
    final fpga = utf8.encode('FPGA fixture for $id');
    await File(p.join(root.path, '$id.bin')).writeAsBytes(mcuPackage);
    await File(p.join(root.path, '$id.fs')).writeAsBytes(fpga);
    releases.add({
      'id': id,
      'label': id == 'stock' ? 'Stock 4.2' : 'ChroMagic 1.0.0-rc.1 (4.2)',
      'version': {
        'mcu': 'v0.13.4',
        'fpga': id == 'stock' ? '18.8' : '18.12',
        'chromatic': id == 'stock' ? 'v4.2' : 'ChroMagic 1.0.0-rc.1 (4.2)',
      },
      'mcu': {
        'file': '$id.bin',
        'sha256': sha256.convert(mcuPackage).toString(),
        if (id == 'stock') 'offset': '0x10000',
      },
      'fpga': {'file': '$id.fs', 'sha256': sha256.convert(fpga).toString()},
    });
  }
  await File(p.join(root.path, 'manifest.json')).writeAsString(
    jsonEncode({
      'schema_version': 1,
      'tools': {
        'esptool': ['python', '-m', 'esptool'],
        'openFPGALoader': ['openFPGALoader'],
      },
      'releases': releases,
    }),
  );
  return FirmwareBundle.load(directory: root.path);
}

void main() {
  late Directory root;
  late FirmwareBundle bundle;
  late FirmwareBackend backend;
  late FakeFirmwareTools tools;
  late FirmwareInstaller installer;
  final updates = <FirmwareProgress>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('firmware-test-');
    bundle = await fixtureBundle(root);
    backend = FirmwareBackend();
    tools = FakeFirmwareTools();
    installer = FirmwareInstaller(
      backend,
      tools: tools,
      reconnectDelay: Duration.zero,
      reconnectAttempts: 2,
    );
    updates.clear();
  });
  tearDown(() => root.delete(recursive: true));
  Future<void> install([int release = 0]) => installer.install(
    bundle,
    bundle.releases[release],
    updates.add,
    logDirectory: root,
  );

  for (final release in [0, 1]) {
    test(
      'installs ${release == 0 ? 'custom' : 'stock'} pair, follows re-enumeration and verifies running versions',
      () async {
        backend.version = bundle.releases[release].version;
        backend.onQuery = (_) {
          expect(tools.commands.last, contains('--write-flash'));
          expect(tools.commands.last, contains('--verify'));
        };
        tools.onCommand = (command) {
          if (command.contains('write_flash')) {
            final application = File(command.last).readAsBytesSync();
            expect(application.length, 256);
            expect(application.first, 0xe9);
          }
          if (command.contains('--write-flash')) backend.ports = ['COM9'];
        };
        await install(release);
        final writes = tools.commands
            .where(
              (c) => c.contains('write_flash') || c.contains('--write-flash'),
            )
            .toList();
        expect(writes.length, 2);
        expect(
          writes.first,
          containsAllInOrder([
            '--port',
            'COM4',
            '--baud',
            '460800',
            'write_flash',
            '0x10000',
          ]),
        );
        expect(
          writes.last,
          containsAllInOrder([
            '--cable',
            'gwu2x',
            '--write-flash',
            '--verify',
            '--reset',
          ]),
        );
        expect(
          writes.expand((command) => command),
          isNot(contains('--busdev-num')),
        );
        expect(writes.expand((c) => c), isNot(contains('erase_flash')));
        expect(writes.first.last, isNot(contains(root.path)));
        expect(
          await File(writes.first.last).exists(),
          false,
        );
        expect(backend.queries.single, [
          '--firmware-info',
          '--port',
          'COM9',
          '--after-flash',
          '--expected-firmware',
          jsonEncode(bundle.releases[release].version),
        ]);
        expect(installer.verifiedPort, 'COM9');
        expect(updates.last.phase, 'Installed and verified');
        expect(
          updates.any(
            (update) =>
                update.phase == 'Verifying...' && update.component == 'FPGA',
          ),
          true,
        );
        expect(
          await File(installer.logPath!).readAsString(),
          contains('both images verified'),
        );
      },
    );
  }
  test('corrupt second image prevents all device access and writes', () async {
    await File(p.join(root.path, 'chromagician.fs')).writeAsString('corrupted');
    await expectLater(
      install(),
      throwsA(
        isA<FirmwareFailure>().having(
          (e) => e.message,
          'message',
          contains('checksum'),
        ),
      ),
    );
    expect(tools.commands, isEmpty);
    expect(backend.queries, isEmpty);
  });
  test(
    'esptool image validation rejects bad application before device access',
    () async {
      tools.imageChecksum = false;
      await expectLater(install(), throwsA(isA<FirmwareFailure>()));
      expect(
        tools.commands.any(
          (command) =>
              command.contains('--detect') || command.contains('write_flash'),
        ),
        false,
      );
      expect(backend.queries, isEmpty);
    },
  );
  test('ambiguous Chromatics prevent flashing', () async {
    backend.ports.add('COM7');
    await expectLater(install(), throwsA(isA<FirmwareFailure>()));
    expect(
      tools.commands.any((command) => command.contains('write_flash')),
      false,
    );
  });
  test(
    'missing programmer or wrong FPGA prevents either image being written',
    () async {
      for (final missing in [true, false]) {
        tools.scan = missing ? '' : '003 008 0x33aa:0x0120 gwu2x';
        tools.detection = 'Unexpected FPGA';
        await expectLater(install(), throwsA(isA<FirmwareFailure>()));
        expect(
          tools.commands.any((command) => command.contains('write_flash')),
          false,
        );
      }
    },
  );
  for (final missingChecksum in [false, true]) {
    test(
      'MCU ${missingChecksum ? 'missing checksum' : 'tool failure'} prevents FPGA write',
      () async {
        tools.failOn = missingChecksum ? null : 'write_flash';
        tools.mcuChecksum = !missingChecksum;
        await expectLater(install(), throwsA(isA<FirmwareFailure>()));
        expect(
          tools.commands.any((command) => command.contains('--write-flash')),
          false,
        );
        expect(updates.last.phase, isNot('Installed and verified'));
      },
    );
  }
  test(
    'FPGA failure explains partial installation and does not report success',
    () async {
      tools.failOn = '--write-flash';
      await expectLater(
        install(),
        throwsA(
          isA<FirmwareFailure>().having(
            (e) => e.message,
            'partial result',
            contains('MCU was updated'),
          ),
        ),
      );
      expect(backend.queries, isEmpty);
      expect(updates.last.phase, isNot('Installed and verified'));
    },
  );
  test(
    'mismatched running versions never report installation success',
    () async {
      backend.version = bundle.releases.last.version;
      await expectLater(
        install(),
        throwsA(
          isA<FirmwareFailure>().having(
            (e) => e.message,
            'message',
            contains('running versions could not be confirmed'),
          ),
        ),
      );
      expect(backend.queries.length, 2);
      expect(backend.queries.first, contains('--after-flash'));
      expect(backend.queries.last, contains('--after-flash'));
      expect(installer.verifiedPort, isNull);
      expect(updates.last.phase, 'Reconnecting...');
    },
  );
  test('read-only version checks never request an MCU restart', () async {
    await installer.readVersion('COM4');
    expect(backend.queries.single, ['--firmware-info', '--port', 'COM4']);
    expect(tools.commands, isEmpty);
  });

  test('a port-open failure does not prevent waking stock on retry', () async {
    backend.version = bundle.releases.last.version;
    backend.onQuery = (arguments) {
      if (backend.queries.length == 1) {
        throw const BackendFailure('serial', 'Port reopening');
      }
      if (!arguments.contains('--after-flash')) {
        throw const BackendFailure('protocol', 'Stock console is asleep');
      }
      final expected = arguments[arguments.indexOf('--expected-firmware') + 1];
      expect(jsonDecode(expected), bundle.releases.last.version);
    };
    await install(1);
    expect(backend.queries.length, 2);
    expect(backend.queries.first, contains('--after-flash'));
    expect(backend.queries.last, contains('--after-flash'));
    expect(updates.last.phase, 'Installed and verified');
  });

  test('a stale version does not disable post-flash recovery', () async {
    backend.onQuery = (arguments) {
      if (backend.queries.length == 1) {
        backend.version = {...bundle.releases.last.version, 'fpga': '18.12'};
      } else if (arguments.contains('--after-flash')) {
        backend.version = bundle.releases.last.version;
      }
    };
    await install(1);
    expect(backend.queries.length, 2);
    expect(updates.last.phase, 'Installed and verified');
  });

  test(
    'stream runner drains both pipes, splits carriage returns and preserves failed exit',
    () async {
      final script = File(p.join(root.path, 'fake_tool.py'));
      await script.writeAsString(
        "import sys\nsys.stderr.write('x' * 200000 + '\\n')\nsys.stdout.write('Writing: 25%\\rWriting: 100%\\r')\nsys.stderr.write('verification failed\\n')\nsys.exit(3)\n",
      );
      final lines = <String>[];
      final result = await ProcessFirmwareTools().run(
        ['python3', script.path],
        lines.add,
        timeout: const Duration(seconds: 5),
      );
      expect(result.exitCode, 3);
      expect(
        lines,
        containsAll(['Writing: 25%', 'Writing: 100%', 'verification failed']),
      );
    },
    skip: Platform.isWindows,
  );
}
