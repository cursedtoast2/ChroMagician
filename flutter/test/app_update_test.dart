import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/app_update.dart';
import 'package:chromatic_pc_backup/releases.dart';
import 'package:chromatic_pc_backup/update_install.dart';
import 'releases_test.dart' show FakeReleases, assetJson, releaseJson;

List<int> fixtureArchive({
  String version = '1.0.1',
  int machine = 62,
  ArchiveFile? extra,
  String? omit,
}) {
  final archive = Archive();
  final elf = List<int>.filled(20, 0)
    ..setRange(0, 6, [0x7f, 69, 76, 70, 2, 1])
    ..[18] = machine;
  for (final name in [
    appExecutable,
    'libexec/$updateHelper',
    'libexec/chromatic-backup',
    'lib/libapp.so',
    'lib/libflutter_linux_gtk.so',
  ]) {
    if (name != omit) {
      archive.add(ArchiveFile.bytes('ChroMagician/$name', elf)..mode = 493);
    }
  }
  archive.add(
    ArchiveFile.string(
      'ChroMagician/data/flutter_assets/version.json',
      jsonEncode({'version': version}),
    ),
  );
  if (extra != null) archive.add(extra);
  return gzip.encode(TarEncoder().encode(archive));
}

void main() {
  late Directory root, installed;
  late FakeReleases transport;
  late AppUpdater updater;
  late GitHubRelease release;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('app-updater-test-');
    installed = await Directory(p.join(root.path, 'live app')).create();
    await File(p.join(installed.path, 'data/flutter_assets/version.json'))
        .create(recursive: true)
        .then((f) => f.writeAsString('{"version":"1.0.0"}'));
    await File(
      p.join(installed.path, 'libexec/$updateHelper'),
    ).create(recursive: true);
    transport = FakeReleases();
    updater = AppUpdater(
      ReleaseClient(
        Directory(p.join(root.path, 'cache')),
        transport: transport,
      ),
      installation: installed,
      platform: 'linux-x64',
    );
  });
  tearDown(() async => root.delete(recursive: true));
  GitHubRelease publish(List<int> bytes) {
    final json = releaseJson(
      'v1.0.1',
      assets: [assetJson(9, 'ChroMagician-1.0.1-linux-x64.tar.gz', bytes)],
    );
    transport.replies['/repos/$appRepository/releases/assets/9'] = bytes;
    return GitHubRelease(appRepository, json);
  }

  test(
    'downloads matching release, stages beside install, keeps current app unchanged',
    () async {
      release = publish(fixtureArchive());
      final phases = <String>[];
      final result =
          await updater.prepare(release, phases.add) as LocalAppUpdate;
      expect(result.work.parent.path, root.path);
      expect(
        await bundleVersion(
          Directory(p.join(result.work.path, 'ChroMagician')),
        ),
        '1.0.1',
      );
      expect(await bundleVersion(installed), '1.0.0');
      expect(phases, ['Downloading update...', 'Preparing update...']);
      expect(
        (await File(
              p.join(result.work.path, 'ChroMagician', appExecutable),
            ).stat()).mode &
            0x49,
        isNonZero,
      );
      await result.discard();
      expect(await result.work.exists(), false);
    },
  );

  test(
    'corrupt download leaves installed app intact and removes staging',
    () async {
      release = publish(fixtureArchive());
      transport.replies['/repos/$appRepository/releases/assets/9'] = [0, 1];
      await expectLater(
        updater.prepare(release, (_) {}),
        throwsA(isA<ReleaseFailure>()),
      );
      expect(await bundleVersion(installed), '1.0.0');
      expect(
        root.listSync().where(
          (e) => p.basename(e.path).startsWith('.chromagician-update-'),
        ),
        isEmpty,
      );
    },
  );

  for (final bad in [
    'version',
    'architecture',
    'missing backend',
    'traversal',
    'absolute path',
    'symlink',
  ]) {
    test('rejects $bad before replacement', () async {
      release = publish(switch (bad) {
        'version' => fixtureArchive(version: '1.0.2'),
        'architecture' => fixtureArchive(machine: 183),
        'missing backend' => fixtureArchive(omit: 'libexec/chromatic-backup'),
        'traversal' => fixtureArchive(
          extra: ArchiveFile.string('ChroMagician/../../escaped', 'bad'),
        ),
        'absolute path' => fixtureArchive(
          extra: ArchiveFile.string(p.join(root.path, 'escaped'), 'bad'),
        ),
        _ => fixtureArchive(
          extra: ArchiveFile.symlink('ChroMagician/link', '../../escaped'),
        ),
      });
      await expectLater(
        updater.prepare(release, (_) {}),
        throwsA(isA<Exception>()),
      );
      expect(await bundleVersion(installed), '1.0.0');
      expect(await File(p.join(root.path, 'escaped')).exists(), false);
    });
  }
}
