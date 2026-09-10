import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/firmware_releases.dart';
import '../tool/build_desktop.dart'
    show publishBundle, packageFirmwareTools, removeBundledFirmwareImages;

void main() {
  test(
    'portable tools survive relocation, preserve arguments, and omit firmware',
    () async {
      final root = await Directory.systemTemp.createTemp('portable tools ');
      addTearDown(() => root.delete(recursive: true));
      final source = await Directory('${root.path}/build').create();
      await Directory('${source.path}/tools').create();
      await Directory('${source.path}/licenses').create();
      for (final name in ['esptool', 'openFPGALoader']) {
        await File('/bin/echo').copy('${source.path}/tools/$name');
      }
      await File(
        '${source.path}/licenses/NOTICE',
      ).writeAsString('upstream notices');
      await File(
        '${source.path}/mcu.bin',
      ).writeAsString('must never be bundled');
      await File('${source.path}/manifest.json').writeAsString(
        jsonEncode({
          'portable_tools': true,
          'tools': {
            'esptool': ['tools/esptool', 'argument with spaces'],
            'openFPGALoader': ['tools/openFPGALoader'],
          },
          'releases': [
            {
              'mcu': {'file': 'mcu.bin'},
            },
          ],
        }),
      );
      final destination = Directory('${root.path}/installed/firmware');
      await packageFirmwareTools(source, destination);
      await source.delete(recursive: true);
      final moved = await destination.parent.rename('${root.path}/moved app');
      final config = await firmwareToolConfiguration(
        directory: '${moved.path}/firmware',
      );
      final command = config.tools['esptool']!;
      final ran = await Process.run(
        command.first,
        command.skip(1).toList(),
        workingDirectory: '/',
      );
      expect(ran.exitCode, 0);
      expect(ran.stdout, 'argument with spaces\n');
      expect(
        await File('${moved.path}/firmware/licenses/NOTICE').readAsString(),
        'upstream notices',
      );
      expect(await File('${moved.path}/firmware/mcu.bin').exists(), false);
      final manifest = await File(
        '${moved.path}/firmware/manifest.json',
      ).readAsString();
      expect(manifest, isNot(contains(root.path)));
      expect(jsonDecode(manifest), isNot(contains('releases')));
    },
    skip: !Platform.isLinux,
  );

  test(
    'portable configuration rejects missing and external executables',
    () async {
      final root = await Directory.systemTemp.createTemp('invalid tools ');
      addTearDown(() => root.delete(recursive: true));
      for (final executable in ['/bin/echo', '../outside', 'tools/missing']) {
        await File('${root.path}/manifest.json').writeAsString(
          jsonEncode({
            'portable_tools': true,
            'tools': {
              'esptool': [executable],
              'openFPGALoader': [executable],
            },
          }),
        );
        await expectLater(
          firmwareToolConfiguration(directory: root.path),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'packages only tool configuration and removes old bundled images',
    () async {
      final root = await Directory.systemTemp.createTemp('firmware-packaging-');
      addTearDown(() => root.delete(recursive: true));
      final source = await Directory('${root.path}/source').create();
      final bundle = await Directory('${root.path}/bundle').create();
      final destination = Directory('${bundle.path}/firmware');
      final config = {
        'schema_version': 1,
        'tools': {
          'esptool': ['esptool'],
          'openFPGALoader': ['openFPGALoader'],
        },
        'releases': [
          for (final id in ['stock', 'chromagician'])
            {
              'id': id,
              'mcu': {'file': '$id/mcu.bin'},
              'fpga': {'file': '$id/fpga.fs'},
            },
        ],
      };
      await File(
        '${source.path}/manifest.json',
      ).writeAsString(jsonEncode(config));
      for (final id in ['stock', 'chromagician']) {
        await Directory('${source.path}/$id').create();
        await File('${source.path}/$id/mcu.bin').writeAsString('MCU');
        await File('${source.path}/$id/fpga.fs').writeAsString('FPGA');
      }
      await packageFirmwareTools(source, destination);
      expect(destination.listSync(recursive: true).whereType<File>().length, 1);
      expect(
        jsonDecode(
          await File('${destination.path}/manifest.json').readAsString(),
        ),
        {'schema_version': 1, 'tools': config['tools']},
      );
      await File(
        '${destination.path}/manifest.json',
      ).writeAsString(jsonEncode(config));
      for (final id in ['stock', 'chromagician']) {
        await Directory('${destination.path}/$id').create();
        await File('${destination.path}/$id/mcu.bin').writeAsString('MCU');
        await File('${destination.path}/$id/fpga.fs').writeAsString('FPGA');
      }
      await File('${bundle.path}/keep-me').writeAsString('application');
      await removeBundledFirmwareImages(bundle);
      expect(destination.listSync(recursive: true).whereType<File>().length, 1);
      expect(
        await File('${bundle.path}/keep-me').readAsString(),
        'application',
      );
      expect(await File('${source.path}/stock/mcu.bin').readAsString(), 'MCU');
    },
  );
  test(
    'publishing preserves a running executable and never removes its path',
    () async {
      final root = await Directory.systemTemp.createTemp('desktop-publish-');
      addTearDown(() => root.delete(recursive: true));
      final live = await Directory(
        '${root.path}/live/libexec',
      ).create(recursive: true);
      final staged = await Directory(
        '${root.path}/staged/libexec',
      ).create(recursive: true);
      final executable = await File('/bin/sleep').copy('${live.path}/backend');
      await File('/bin/true').copy('${staged.path}/backend');
      final retiredFiles = [
        'setup-usb.sh',
        '70-chromagician.rules',
        'LINUX-SETUP.md',
        'WINDOWS-SETUP.md',
      ];
      for (final name in retiredFiles) {
        await File('${live.parent.path}/$name').writeAsString('retired setup');
      }
      final process = await Process.start(executable.path, ['1']);
      var missing = false;
      final monitor = Timer.periodic(const Duration(milliseconds: 1), (_) {
        missing |= !executable.existsSync();
      });
      try {
        await publishBundle(staged.parent, live.parent);
      } finally {
        monitor.cancel();
      }
      expect(missing, false);
      expect(await process.exitCode, 0);
      expect((await Process.run(executable.path, [])).exitCode, 0);
      expect(await File('${executable.path}.incoming').exists(), false);
      for (final name in retiredFiles) {
        expect(await File('${live.parent.path}/$name').exists(), false);
      }
    },
    skip: !Platform.isLinux,
  );
}
