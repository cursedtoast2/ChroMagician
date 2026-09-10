import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/releases.dart';
import 'package:chromatic_pc_backup/firmware_releases.dart';
import 'package:chromatic_pc_backup/updates.dart';

class FakeReleases extends ReleaseTransport {
  final replies = <String, List<int>>{};
  final calls = <String>[];
  bool offline = false;
  void json(String path, Object value) =>
      replies[path] = utf8.encode(jsonEncode(value));
  @override
  Future<List<int>> get(
    Uri uri, {
    bool binary = false,
    int limit = 2 * 1024 * 1024,
  }) async {
    calls.add(uri.path);
    if (offline || !replies.containsKey(uri.path)) {
      throw const ReleaseFailure('Offline');
    }
    return replies[uri.path]!;
  }

  void list(String repo, List<Map<String, dynamic>> releases) =>
      json('/repos/$repo/releases', releases);
}

Map<String, dynamic> releaseJson(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  List<Map<String, dynamic>> assets = const [],
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'assets': assets,
};
Map<String, dynamic> assetJson(int id, String name, List<int> bytes) => {
  'id': id,
  'name': name,
  'size': bytes.length,
  'digest': 'sha256:${sha256.convert(bytes)}',
};

void main() {
  late Directory temp;
  late FakeReleases transport;
  late ReleaseClient client;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('release-tests-');
    transport = FakeReleases();
    client = ReleaseClient(temp, transport: transport);
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'compares release versions numerically including RCs and stock tags',
    () {
      expect(releaseVersion('v1.10.0')! > releaseVersion('1.9.0')!, isTrue);
      expect(releaseVersion('1.0.0')! > releaseVersion('1.0.0-rc.10')!, isTrue);
      expect(
        releaseVersion('1.0.0-rc.10')! > releaseVersion('1.0.0-rc.2')!,
        isTrue,
      );
      expect(
        releaseVersion('ChroMagic 1.0.0-rc.1 (4.2)'),
        releaseVersion('v1.0.0-rc.1'),
      );
      expect(releaseVersion('v18.8'), releaseVersion('18.8.0'));
      expect(releaseVersion('broken'), isNull);
    },
  );

  test(
    'finds highest version, skips drafts, and supports RC releases',
    () async {
      transport.list(appRepository, [
        releaseJson('v1.0.0'),
        releaseJson('v9.0.0', draft: true),
        releaseJson('v2.0.0-rc.1', prerelease: true),
        releaseJson('not-a-version'),
      ]);
      expect((await client.latest(appRepository))!.tag, 'v2.0.0-rc.1');
      expect(
        (await client.latest(appRepository, prereleases: false))!.tag,
        'v1.0.0',
      );
    },
  );

  test(
    'verified cache is reused offline, corruption is rejected and replaced',
    () async {
      final bytes = utf8.encode('valid image');
      final release = GitHubRelease(
        firmwareRepository,
        releaseJson('v1.0.0', assets: [assetJson(20, 'fpga.fs', bytes)]),
      );
      final url = '/repos/$firmwareRepository/releases/assets/20';
      transport.replies[url] = bytes;
      final file = await client.download(release, release.assets.single);
      transport.offline = true;
      expect(
        (await client.download(release, release.assets.single)).path,
        file.path,
      );
      expect(transport.calls.length, 1);
      await file.writeAsString('corruption!');
      await expectLater(
        client.download(release, release.assets.single),
        throwsA(isA<ReleaseFailure>()),
      );
      transport.offline = false;
      transport.replies[url] = utf8.encode('bad response');
      await expectLater(
        client.download(release, release.assets.single),
        throwsA(isA<ReleaseFailure>()),
      );
      transport.replies[url] = bytes;
      expect(
        await (await client.download(
          release,
          release.assets.single,
        )).readAsBytes(),
        bytes,
      );
      expect(
        temp
            .listSync()
            .whereType<Directory>()
            .expand((d) => d.listSync())
            .where((f) => p.basename(f.path).startsWith('.download-')),
        isEmpty,
      );
    },
  );

  test(
    'only firmware resolution falls back to cached release during outage',
    () async {
      transport.list(firmwareRepository, [releaseJson('v1.0.0')]);
      await client.latest(firmwareRepository);
      transport.offline = true;
      expect(
        (await client.latest(firmwareRepository, allowCached: true))!.tag,
        'v1.0.0',
      );
      await expectLater(
        client.latest(firmwareRepository),
        throwsA(isA<ReleaseFailure>()),
      );
    },
  );

  test(
    'ignore persists per app release, newer releases still prompt',
    () async {
      transport.list(appRepository, [releaseJson('v1.1.0')]);
      transport.list(firmwareRepository, [
        releaseJson('v1.0.0-rc.2', prerelease: true),
      ]);
      final updates = ReleaseUpdates(client, '1.0.0');
      await updates.check();
      expect(updates.appUpdate!.tag, 'v1.1.0');
      expect(
        updates.firmwareAvailable({
          'chromatic': 'ChroMagic 1.0.0-rc.1 (4.2)',
        }, hasChroMagic: true),
        isTrue,
      );
      expect(
        updates.firmwareAvailable({'chromatic': '4.2 CM'}, hasChroMagic: true),
        isTrue,
      );
      expect(
        updates.firmwareAvailable({'chromatic': 'v4.2'}, hasChroMagic: false),
        isFalse,
      );
      expect(updates.firmwareAvailable(null, hasChroMagic: false), isFalse);
      await updates.ignore(updates.appUpdate!);
      updates.dispose();
      final restart = ReleaseUpdates(client, '1.0.0');
      await restart.check();
      expect(restart.appUpdate, isNull);
      transport.list(appRepository, [releaseJson('v1.2.0')]);
      await restart.check();
      expect(restart.appUpdate!.tag, 'v1.2.0');
      restart.dispose();
    },
  );

  test(
    'stock downloads correct image pair and stages only MCU application',
    () async {
      final application = List<int>.filled(256, 0)..[0] = 0xe9;
      final merged = [...List<int>.filled(0x10000, 0xff), ...application];
      final fpga = utf8.encode('FPGA');
      transport.list(stockMcuRepository, [
        releaseJson('v4.2', assets: [assetJson(1, 'v0.13.4.bin', merged)]),
      ]);
      transport.list(stockFpgaRepository, [
        releaseJson('v18.8', assets: [assetJson(2, 'v18.8_20251224.fs', fpga)]),
      ]);
      transport.replies['/repos/$stockMcuRepository/releases/assets/1'] =
          merged;
      transport.replies['/repos/$stockFpgaRepository/releases/assets/2'] = fpga;
      final repository = FirmwareReleases(client);
      final bundle = await repository.prepare('stock', {}, (_) {});
      expect(bundle.releases.single.version, {
        'mcu': 'v0.13.4',
        'fpga': '18.8',
        'chromatic': 'v4.2',
      });
      final staging = await temp.createTemp('staging-');
      expect(
        await (await bundle.stage(
          bundle.releases.single.mcu,
          staging,
          'mcu.bin',
        )).readAsBytes(),
        application,
      );
      transport.offline = true;
      final cached = await repository.prepare('stock', {}, (_) {});
      expect(cached.releases.single.version, bundle.releases.single.version);
    },
  );

  test(
    'custom firmware manifest binds MCU and FPGA to the same release',
    () async {
      final mcu = List<int>.filled(256, 0)..[0] = 0xe9;
      final fpga = utf8.encode('FPGA');
      final manifest = utf8.encode(
        jsonEncode({
          'schema_version': 1,
          'version': {
            'chromatic': 'ChroMagic 1.0.0-rc.1 (4.2)',
            'mcu': 'v0.13.4',
            'fpga': '18.37',
          },
          'mcu': {'file': 'mcu.bin', 'sha256': sha256.convert(mcu).toString()},
          'fpga': {
            'file': 'fpga.fs',
            'sha256': sha256.convert(fpga).toString(),
          },
        }),
      );
      final assets = [
        assetJson(1, 'firmware.json', manifest),
        assetJson(2, 'mcu.bin', mcu),
        assetJson(3, 'fpga.fs', fpga),
      ];
      transport.list(firmwareRepository, [
        releaseJson('v1.0.0-rc.1', prerelease: true, assets: assets),
      ]);
      for (final (id, bytes) in [(1, manifest), (2, mcu), (3, fpga)]) {
        transport.replies['/repos/$firmwareRepository/releases/assets/$id'] =
            bytes;
      }
      final repository = FirmwareReleases(client);
      final bundle = await repository.prepare('chromagician', {}, (_) {});
      final stage = await temp.createTemp('stage-');
      expect(
        await (await bundle.stage(
          bundle.releases.single.fpga,
          stage,
          'fpga.fs',
        )).readAsBytes(),
        fpga,
      );
      transport.list(firmwareRepository, [
        releaseJson('v1.0.0-rc.2', prerelease: true, assets: assets),
      ]);
      await expectLater(
        repository.prepare('chromagician', {}, (_) {}),
        throwsA(isA<ReleaseFailure>()),
      );
    },
  );

  test(
    'missing digest, mismatching manifest digest, ambiguous stock fail before install',
    () async {
      final asset = assetJson(1, 'mcu.bin', [1, 2, 3]);
      final release = GitHubRelease(
        firmwareRepository,
        releaseJson('v1.0.0', assets: [asset]),
      );
      await expectLater(
        client.download(release, release.assets.single, expectedHash: '0' * 64),
        throwsA(isA<ReleaseFailure>()),
      );
      expect(transport.calls, isEmpty);
      asset.remove('digest');
      final noDigest = GitHubRelease(
        firmwareRepository,
        releaseJson('v1.0.0', assets: [asset]),
      );
      await expectLater(
        client.download(noDigest, noDigest.assets.single),
        throwsA(isA<ReleaseFailure>()),
      );
      transport.list(stockMcuRepository, [
        releaseJson(
          'v4.2',
          assets: [
            asset,
            {...asset, 'id': 2},
          ],
        ),
      ]);
      transport.list(stockFpgaRepository, [releaseJson('v18.8')]);
      await expectLater(
        FirmwareReleases(client).prepare('stock', {}, (_) {}),
        throwsA(isA<ReleaseFailure>()),
      );
      expect(
        transport.calls.every((path) => !path.contains('/assets/')),
        isTrue,
      );
    },
  );
}
