import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/backend.dart';
import 'package:chromatic_pc_backup/firmware.dart';

class ReadOnlyFirmwareTools implements FirmwareTools {
  final native = ProcessFirmwareTools();
  final commands = <List<String>>[];
  static const stopped = 'Preflight passed; test blocked the flash command.';
  @override
  Future<ToolResult> run(
    List<String> command,
    void Function(String) onLine, {
    Duration? timeout,
  }) async {
    commands.add(command);
    if (command.contains('write_flash')) throw const FirmwareFailure(stopped);
    if (![
      'version',
      '--version',
      'image_info',
      '--scan-usb',
      '--detect',
    ].any(command.contains)) {
      throw const FirmwareFailure('Test refused an unapproved tool command.');
    }
    return native.run(command, onLine, timeout: timeout);
  }
}

void main() {
  final location = Platform.environment['CHROMATIC_TEST_FIRMWARE'];
  final live = Platform.environment['CHROMATIC_TEST_LIVE_PREFLIGHT'] == '1';
  test(
    'actual console reports the running firmware pair',
    () async {
      final bundle = await FirmwareBundle.load(directory: location);
      final backend = ProcessBackend(ProcessBackend.resolveExecutable());
      final ports = await backend.devices();
      expect(ports.length, 1);
      final version = await FirmwareInstaller(
        backend,
      ).readVersion(ports.single);
      expect(
        bundle.releases.any(
          (release) => [
            'mcu',
            'fpga',
            'chromatic',
          ].every((key) => version[key] == release.version[key]),
        ),
        true,
        reason: 'Running firmware: $version',
      );
    },
    skip: location == null || !live ? 'Opt-in read-only hardware test.' : false,
  );
  test(
    'actual stock and ChroMagic applications pass native esptool validation',
    () async {
      final bundle = await FirmwareBundle.load(directory: location);
      final staging = await Directory.systemTemp.createTemp(
        'firmware-artifacts-test-',
      );
      addTearDown(() => staging.delete(recursive: true));
      final native = ReadOnlyFirmwareTools();
      for (final release in bundle.releases) {
        final file = await bundle.stage(release.mcu, staging, 'mcu.bin');
        final original = await File(
          '${bundle.directory.path}/${release.mcu['file']}',
        ).readAsBytes();
        final offset = int.parse(release.mcu['offset'] ?? '0');
        expect(await file.readAsBytes(), original.sublist(offset));
        if (release.id == 'stock') expect(offset, 0x10000);
        final result = await native.run(
          [
            ...bundle.tools['esptool']!,
            '--chip',
            'esp32',
            'image_info',
            file.path,
          ],
          (_) {},
          timeout: const Duration(seconds: 20),
        );
        expect(result.exitCode, 0, reason: result.output);
        expect(
          result.output,
          contains(RegExp(r'Checksum: [0-9a-f]+ \(valid\)')),
        );
        expect(
          result.output,
          contains(RegExp(r'Validation Hash: [0-9a-f]+ \(valid\)')),
        );
        await bundle.stage(release.fpga, staging, 'fpga.fs');
      }
    },
    skip: location == null
        ? 'Set CHROMATIC_TEST_FIRMWARE to test release artifacts.'
        : false,
  );

  test(
    'actual installer reaches first write with native tools and attached Chromatic',
    () async {
      final bundle = await FirmwareBundle.load(directory: location);
      final backend = ProcessBackend(ProcessBackend.resolveExecutable());
      final logs = await Directory.systemTemp.createTemp(
        'firmware-preflight-test-',
      );
      addTearDown(() => logs.delete(recursive: true));
      for (final release in bundle.releases) {
        final readonly = ReadOnlyFirmwareTools();
        final installer = FirmwareInstaller(backend, tools: readonly);
        final progress = <FirmwareProgress>[];
        await expectLater(
          installer.install(bundle, release, progress.add, logDirectory: logs),
          throwsA(
            isA<FirmwareFailure>().having(
              (e) => e.message,
              'preflight completion',
              contains(ReadOnlyFirmwareTools.stopped),
            ),
          ),
        );
        expect(progress.last.component, 'MCU');
        expect(readonly.commands.last, contains('write_flash'));
        expect(
          readonly.commands.any((command) => command.contains('--write-flash')),
          false,
        );
      }
    },
    skip: location == null || !live
        ? 'Set CHROMATIC_TEST_FIRMWARE and CHROMATIC_TEST_LIVE_PREFLIGHT=1 for read-only hardware preflight.'
        : false,
  );
}
