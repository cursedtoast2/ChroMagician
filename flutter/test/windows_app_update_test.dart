import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/app_update.dart';
import 'package:chromatic_pc_backup/releases.dart';
import 'package:chromatic_pc_backup/update_install.dart';
import 'releases_test.dart' show FakeReleases, assetJson, releaseJson;

List<int> windowsArchive({
  String version = '1.0.1',
  int machine = 0x8664,
  String? omit,
  List<ArchiveFile> extra = const [],
}) {
  final pe = Uint8List(90)..setRange(0, 2, [0x4d, 0x5a]);
  final view = ByteData.sublistView(pe);
  view.setUint32(60, 64, Endian.little);
  view.setUint32(64, 0x4550, Endian.little);
  view.setUint16(68, machine, Endian.little);
  view.setUint16(88, 0x20b, Endian.little);
  final archive = Archive();
  for (final name in [
    'chromatic_pc_backup.exe',
    'libexec/chromagician-update.exe',
    'libexec/chromatic-backup.exe',
    'flutter_windows.dll',
  ]) {
    if (name != omit) archive.add(ArchiveFile.bytes('ChroMagician/$name', pe));
  }
  archive.add(
    ArchiveFile.bytes(
      'ChroMagician/data/app.so',
      List<int>.filled(20, 0)
        ..setRange(0, 6, [0x7f, 69, 76, 70, 2, 1])
        ..[18] = 62,
    ),
  );
  archive.add(
    ArchiveFile.string(
      'ChroMagician/data/flutter_assets/version.json',
      jsonEncode({'version': version}),
    ),
  );
  for (final file in extra) {
    archive.add(file);
  }
  final encoded = ZipEncoder().encode(archive);
  for (final file in extra.where((f) => f.name.contains('\\'))) {
    final normal = utf8.encode(file.name.replaceAll('\\', '/'));
    final malformed = utf8.encode(file.name);
    for (var i = 0; i <= encoded.length - normal.length; i++) {
      if (List.generate(
        normal.length,
        (j) => encoded[i + j] == normal[j],
      ).every((v) => v)) {
        encoded.setRange(i, i + normal.length, malformed);
      }
    }
  }
  return encoded;
}

void main() {
  late Directory root, installed;
  late AppUpdater updater;
  late FakeReleases transport;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('windows-update-test-');
    installed = await Directory(p.join(root.path, 'live app')).create();
    await File(p.join(installed.path, 'data/flutter_assets/version.json'))
        .create(recursive: true)
        .then((f) => f.writeAsString('{"version":"1.0.0"}'));
    await File(
      p.join(installed.path, 'libexec/chromagician-update.exe'),
    ).create(recursive: true);
    transport = FakeReleases();
    updater = AppUpdater(
      ReleaseClient(
        Directory(p.join(root.path, 'cache')),
        transport: transport,
      ),
      installation: installed,
      platform: 'windows-x64',
    );
  });
  tearDown(() async => root.delete(recursive: true));
  GitHubRelease publish(List<int> bytes) {
    transport.replies['/repos/$appRepository/releases/assets/9'] = bytes;
    return GitHubRelease(
      appRepository,
      releaseJson(
        'v1.0.1',
        assets: [assetJson(9, 'ChroMagician-1.0.1-windows-x64.zip', bytes)],
      ),
    );
  }

  test(
    'Windows ZIP downloads, verifies, stages native files and preserves current app',
    () async {
      final result =
          await updater.prepare(
                publish(
                  windowsArchive(
                    extra: [
                      ArchiveFile.bytes(
                        'ChroMagician/data/large',
                        List<int>.generate(2 * 1024 * 1024, (i) => i % 251),
                      ),
                    ],
                  ),
                ),
                (_) {},
              )
              as LocalAppUpdate;
      expect(
        await bundleVersion(
          Directory(p.join(result.work.path, 'ChroMagician')),
        ),
        '1.0.1',
      );
      expect(await bundleVersion(installed), '1.0.0');
      expect(
        await File(
          p.join(result.work.path, 'chromagician-update.exe'),
        ).exists(),
        true,
      );
      expect(
        await File(
          p.join(result.work.path, 'ChroMagician/data/large'),
        ).length(),
        2 * 1024 * 1024,
      );
      await result.discard();
      expect(await result.work.exists(), false);
    },
  );
  final invalid = <String, List<int> Function()>{
    'wrong version': () => windowsArchive(version: '1.0.2'),
    'wrong architecture': () => windowsArchive(machine: 0xaa64),
    'missing backend': () =>
        windowsArchive(omit: 'libexec/chromatic-backup.exe'),
    'symlink': () => windowsArchive(
      extra: [
        ArchiveFile.string('ChroMagician/link', '../../escaped')..mode = 0xa1ff,
      ],
    ),
    'case alias': () => windowsArchive(
      extra: [ArchiveFile.string('ChroMagician/FLUTTER_WINDOWS.DLL', 'bad')],
    ),
    'invalid plugin DLL': () => windowsArchive(
      extra: [ArchiveFile.string('ChroMagician/plugin.dll', 'bad')],
    ),
    for (final name in [
      '../escaped',
      'C:/escaped',
      '//server/file',
      'ChroMagician/../escaped',
      'ChroMagician/a:stream',
      'ChroMagician/CON.txt',
      'ChroMagician/COM1',
      'ChroMagician/name.',
      'ChroMagician/name ',
      'ChroMagician/a\\b',
      'ChroMagician/a\u0000b',
    ])
      name: () => windowsArchive(extra: [ArchiveFile.string(name, 'bad')]),
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} before replacing Windows app', () async {
      await expectLater(
        updater.prepare(publish(entry.value()), (_) {}),
        throwsA(isA<Exception>()),
      );
      expect(await bundleVersion(installed), '1.0.0');
      expect(
        root.listSync().where(
          (e) => p.basename(e.path).startsWith('.chromagician-update-'),
        ),
        isEmpty,
      );
    });
  }
  test('rejects corrupt Windows download before extraction', () async {
    final release = publish(windowsArchive());
    transport.replies['/repos/$appRepository/releases/assets/9'] = [0, 1];
    await expectLater(
      updater.prepare(release, (_) {}),
      throwsA(isA<ReleaseFailure>()),
    );
    expect(await bundleVersion(installed), '1.0.0');
  });
}
