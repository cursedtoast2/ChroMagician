import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/app_update.dart';
import 'package:chromatic_pc_backup/firmware.dart';
import 'package:chromatic_pc_backup/firmware_releases.dart';

void main() {
  test(
    'released Windows tools run after relocation without Python or developer PATH',
    () async {
      final archive = File(
        Platform.environment['CHROMAGIC_TEST_WINDOWS_ZIP']!,
      ).absolute;
      final version = RegExp(
        r'ChroMagician-(.*)-windows-x64.zip$',
      ).firstMatch(archive.path)![1]!;
      final root = await Directory.systemTemp.createTemp('ChroMagician é & ');
      addTearDown(() => root.delete(recursive: true));
      await extractAppUpdate(archive.path, root.path, version, 'windows-x64');
      final bundle = Directory(p.join(root.path, 'ChroMagician'));
      final config = await firmwareToolConfiguration(
        directory: p.join(bundle.path, 'firmware'),
      );
      final environment = {
        'PATH': p.join(Platform.environment['SystemRoot']!, 'System32'),
        'PYTHONHOME': p.join(root.path, 'no-python'),
        'PYTHONPATH': p.join(root.path, 'no-python'),
      };
      Future<ProcessResult> run(String name, List<String> args) async {
        final command = config.tools[name]!;
        expect(p.isWithin(bundle.path, command.first), isTrue);
        final process = await Process.start(
          command.first,
          [...command.skip(1), ...args],
          environment: environment,
          workingDirectory: root.path,
        );
        final stdout = process.stdout.transform(utf8.decoder).join();
        final stderr = process.stderr.transform(utf8.decoder).join();
        final code = await process.exitCode.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            process.kill();
            throw StateError('$name timed out');
          },
        );
        final result = ProcessResult(
          process.pid,
          code,
          await stdout,
          await stderr,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        return result;
      }

      final esp = await run('esptool', ['version']);
      expect('${esp.stdout}${esp.stderr}', contains('4.12.0'));
      final fpga = await run('openFPGALoader', ['--version']);
      expect('${fpga.stdout}${fpga.stderr}', contains('1.1.1'));
      final cables = await run('openFPGALoader', ['--list-cables']);
      expect('${cables.stdout}${cables.stderr}', contains('gwu2x'));
      final scan = await run('openFPGALoader', ['--scan-usb']);
      expect('${scan.stdout}${scan.stderr}', isNot(contains('33aa:0120')));

      final source = await File(
        Platform.environment['CHROMAGIC_TEST_STOCK_MCU']!,
      ).copy(p.join(root.path, 'stock.bin'));
      const expected =
          'f936c98b7d5e07299c0e0441d1f99dd88c4be875188e5cda14fc66a3f4ca84a8';
      expect((await sha256.bind(source.openRead()).first).toString(), expected);
      final stage = await Directory(p.join(root.path, 'image')).create();
      final image = await FirmwareBundle(root, {}, []).stage(
        {'file': 'stock.bin', 'sha256': expected, 'offset': '65536'},
        stage,
        'mcu.bin',
      );
      final info = await run('esptool', [
        '--chip',
        'esp32',
        'image_info',
        image.path,
      ]);
      final text = '${info.stdout}${info.stderr}';
      expect(text, matches(r'Checksum: [0-9a-fA-F]+ \(valid\)'));
      expect(text, matches(r'Validation Hash: [0-9a-fA-F]+ \(valid\)'));
      final manifest =
          jsonDecode(
                await File(
                  p.join(bundle.path, 'firmware/manifest.json'),
                ).readAsString(),
              )
              as Map;
      expect(manifest.containsKey('releases'), isFalse);
      expect(
        await File(p.join(bundle.path, 'firmware/mcu.bin')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(bundle.path, 'firmware/fpga.fs')).exists(),
        isFalse,
      );
      expect(
        await File(
          p.join(bundle.path, 'firmware/licenses/libusb.txt'),
        ).exists(),
        isTrue,
      );
      await bundle.rename(p.join(root.path, 'finished'));
    },
    skip:
        !Platform.isWindows ||
        !Platform.environment.containsKey('CHROMAGIC_TEST_WINDOWS_ZIP'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
