import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/releases.dart';
import 'package:chromatic_pc_backup/firmware_releases.dart';
import 'package:chromatic_pc_backup/firmware.dart';
import 'package:chromatic_pc_backup/updates.dart';

class CountingGitHub extends GitHubTransport {
  int binaries = 0;
  @override
  Future<List<int>> get(
    Uri uri, {
    bool binary = false,
    int limit = 2 * 1024 * 1024,
  }) {
    if (binary) binaries++;
    return super.get(uri, binary: binary, limit: limit);
  }
}

void main() {
  test(
    'published app prerelease is offered to RC1 and not to the same version',
    () async {
      final expected = Platform.environment['CHROMAGIC_TEST_APP_RELEASE']!;
      final temp = await Directory.systemTemp.createTemp('app-release-');
      addTearDown(() => temp.delete(recursive: true));
      final client = ReleaseClient(temp);
      final older = ReleaseUpdates(client, '1.0.0-rc.1');
      addTearDown(older.dispose);
      await older.check();
      expect(older.appUpdate?.tag, expected);
      expect(
        older.appUpdate?.page.toString(),
        'https://github.com/$appRepository/releases/tag/$expected',
      );
      expect(older.appUpdate!.assets, isNotEmpty);
      final current = ReleaseUpdates(
        client,
        releaseVersion(expected)!.toString(),
      );
      addTearDown(current.dispose);
      await current.check();
      expect(current.appUpdate, isNull);
    },
    skip: Platform.environment['CHROMAGIC_TEST_APP_RELEASE'] == null,
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'private ChroMagic release authenticates, validates and reuses its image pair without USB',
    () async {
      final expectedPath =
          Platform.environment['CHROMAGIC_TEST_EXPECTED_FIRMWARE'];
      expect(
        expectedPath,
        isNotNull,
        reason:
            'Supply the independently prepared local firmware.json to validate the published release.',
      );
      final expected =
          jsonDecode(await File(expectedPath!).readAsString())
              as Map<String, dynamic>;
      final temp = await Directory.systemTemp.createTemp('private-release-');
      addTearDown(() => temp.delete(recursive: true));
      final transport = CountingGitHub();
      final client = ReleaseClient(temp, transport: transport);
      final source = FirmwareReleases(client);
      final config = await firmwareToolConfiguration();
      final bundle = await source.prepare('chromagician', config.tools, (_) {});
      final release = bundle.releases.single;
      expect(
        release.version,
        Map<String, String>.from(expected['version'] as Map),
      );
      expect(release.mcu['sha256'], (expected['mcu'] as Map)['sha256']);
      expect(release.fpga['sha256'], (expected['fpga'] as Map)['sha256']);
      final stage = await Directory(p.join(temp.path, 'staged')).create();
      final mcu = await bundle.stage(release.mcu, stage, 'mcu.bin');
      await bundle.stage(release.fpga, stage, 'fpga.fs');
      final checked = await ProcessFirmwareTools().run(
        [
          ...bundle.tools['esptool']!,
          '--chip',
          'esp32',
          'image_info',
          '--version',
          '2',
          mcu.path,
        ],
        (_) {},
        timeout: const Duration(seconds: 20),
      );
      expect(checked.exitCode, 0, reason: checked.output);
      expect(checked.output, contains('(valid)'));
      expect(transport.binaries, 3);
      await source.prepare('chromagician', config.tools, (_) {});
      expect(
        transport.binaries,
        3,
        reason: 'Verified cached files must be reused.',
      );

      final updates = ReleaseUpdates(client, '1.0.0-rc.1');
      addTearDown(updates.dispose);
      await updates.check();
      expect(
        updates.firmware?.version,
        releaseVersion((expected['version'] as Map)['chromatic'] as String),
      );
      expect(
        updates.firmwareAvailable({'chromatic': '4.2 CM'}, hasChroMagic: true),
        isTrue,
      );
      expect(
        updates.firmwareAvailable(release.version, hasChroMagic: true),
        isFalse,
      );
    },
    skip:
        Platform.environment['CHROMAGIC_TEST_PRIVATE_RELEASE_DOWNLOAD'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'official release downloads verify, cache, and pass native MCU validation without USB',
    () async {
      final temp = await Directory.systemTemp.createTemp('real-releases-');
      addTearDown(() => temp.delete(recursive: true));
      final transport = CountingGitHub();
      final source = FirmwareReleases(
        ReleaseClient(temp, transport: transport),
      );
      final config = await firmwareToolConfiguration();
      final bundle = await source.prepare('stock', config.tools, (_) {});
      final release = bundle.releases.single;
      expect(release.version, {
        'chromatic': 'v4.2',
        'mcu': 'v0.13.4',
        'fpga': '18.8',
      });
      expect(
        release.mcu['sha256'],
        'f936c98b7d5e07299c0e0441d1f99dd88c4be875188e5cda14fc66a3f4ca84a8',
      );
      expect(
        release.fpga['sha256'],
        '7f5c7811d260f850dfba408178748a5c1aab803f7419bcb34adde70395a7a8af',
      );
      final stage = await Directory(p.join(temp.path, 'staged')).create();
      final mcu = await bundle.stage(release.mcu, stage, 'mcu.bin');
      await bundle.stage(release.fpga, stage, 'fpga.fs');
      final checked = await ProcessFirmwareTools().run(
        [
          ...bundle.tools['esptool']!,
          '--chip',
          'esp32',
          'image_info',
          '--version',
          '2',
          mcu.path,
        ],
        (_) {},
        timeout: const Duration(seconds: 20),
      );
      expect(checked.exitCode, 0, reason: checked.output);
      expect(checked.output, contains('(valid)'));
      expect(transport.binaries, 2);
      await source.prepare('stock', config.tools, (_) {});
      expect(
        transport.binaries,
        2,
        reason: 'The second installation must reuse verified cached images.',
      );
    },
    skip: Platform.environment['CHROMAGIC_TEST_RELEASE_DOWNLOAD'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
