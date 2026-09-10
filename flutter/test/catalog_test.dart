import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/catalog.dart';

const metadataHeader = <String, dynamic>{
  'title': 'PM_CRYSTAL',
  'color': true,
  'rom_size': 2097152,
  'save_size': 32768,
  'global_checksum': '18d2',
  'header_checksum': 38,
  'rom_version': 1,
};

const metadataRecord = <String, dynamic>{
  'id': 'igdb-1514',
  'title': 'Pokémon Crystal Version',
  'rating': 90.0,
  'rating_count': 12,
  'developers': ['Game Freak'],
  'publishers': ['Nintendo'],
  'genres': ['Role-playing (RPG)', 'Adventure'],
  'summary': 'Explore Johto, catch Pokémon, and challenge the Pokémon League.',
  'localizations': [],
  'releases': [
    {
      'system': 'gbc',
      'human': 'Dec 14, 2000',
      'y': 2000,
      'release_region': {'region': 'japan'},
    },
    {
      'system': 'gbc',
      'human': 'Jul 30, 2001',
      'y': 2001,
      'release_region': {'region': 'north_america'},
    },
  ],
};

final fixtureCover = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
);

Future<Json> put(Directory site, String path, List<int> bytes) async {
  final file = File('${site.path}/$path');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
  return {
    'path': path,
    'sha256': sha256.convert(bytes).toString(),
    'bytes': bytes.length,
  };
}

Future<void> makeCatalog(
  Directory site, {
  bool ambiguous = false,
  bool badCover = false,
  Json Function(Json entry)? identityIndexes,
}) async {
  final cover = await put(site, 'covers/crystal.png', fixtureCover);
  final record = await put(
    site,
    'catalog/v1/games/crystal.json',
    utf8.encode(jsonEncode({...metadataRecord, 'cover': cover})),
  );
  if (badCover) {
    await File('${site.path}/covers/crystal.png').writeAsString('corrupt');
  }
  final entry = {
    'id': 'igdb-1514',
    'record': record,
    'region': 'NTSC-U',
    'release_name': 'Pokemon - Crystal Version (USA, Europe) (Rev 1)',
  };
  final identity = await put(
    site,
    'catalog/v1/identity.json',
    utf8.encode(
      jsonEncode({
        'headers': {
          cartridgeKey(metadataHeader)!: [
            entry,
            if (ambiguous) {...entry, 'id': 'another-game'},
          ],
        },
        'crc32': {
          '2097152:3358e30a': [entry],
        },
        ...?identityIndexes?.call(entry),
      }),
    ),
  );
  await put(
    site,
    'catalog/v1/manifest.json',
    utf8.encode(
      jsonEncode({
        'schema_version': 1,
        'asset_base': 'site-root',
        'identity': identity,
      }),
    ),
  );
}

void main() {
  late Directory root;
  late Directory site;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('chromatic-catalog-test-');
    site = Directory('${root.path}/site');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'header hash identifies a regional game despite different title spelling',
    () async {
      await makeCatalog(
        site,
        identityIndexes: (entry) => {
          'header_sha1': {
            'a' * 40: [
              {
                ...entry,
                'region': 'NTSC-J',
                'system': 'gbc',
                'rom_size': 2097152,
              },
              {...entry, 'id': 'monochrome-edition', 'system': 'gb'},
            ],
          },
        },
      );
      final catalog = GameCatalog(
        source: site.uri,
        cache: Directory('${root.path}/hash-cache'),
      );
      addTearDown(catalog.dispose);
      final header = {
        ...metadataHeader,
        'title': 'JAPAN_TITLE',
        'header_sha1': 'a' * 40,
      };
      final game = await catalog.lookup(header);
      expect(game!.releaseDate, 'Dec 14, 2000');
      expect(game.coverBytes, fixtureCover);
      expect(await catalog.lookup({...header, 'rom_size': 1048576}), null);
    },
  );

  for (final unresolved in [false, true]) {
    test(
      'unlisted revision uses a family only when all identities agree ($unresolved)',
      () async {
        await makeCatalog(
          site,
          identityIndexes: (entry) => {
            'header_families': {
              'gbc|PM_CRYSTAL|2097152': [
                entry,
                if (unresolved) {'id': null},
              ],
            },
          },
        );
        final catalog = GameCatalog(
          source: site.uri,
          cache: Directory('${root.path}/family-cache'),
        );
        addTearDown(catalog.dispose);
        final game = await catalog.lookup({
          ...metadataHeader,
          'global_checksum': 'ffff',
          'rom_version': 2,
        });
        expect(game?.title, unresolved ? null : 'Pokémon Crystal Version');
        expect(game?.releaseName, null);
      },
    );
  }

  test(
    'local catalog resolves header and region without any ROM read',
    () async {
      await makeCatalog(site);
      final catalog = GameCatalog(
        source: site.uri,
        cache: Directory('${root.path}/cache'),
      );
      addTearDown(catalog.dispose);
      final game = await catalog.lookup(metadataHeader);
      expect(game!.title, 'Pokémon Crystal Version');
      expect(
        game.releaseName,
        'Pokemon - Crystal Version (USA, Europe) (Rev 1)',
      );
      expect(game.releaseDate, 'Jul 30, 2001');
      expect(game.stars, 4.5);
      expect(game.coverBytes, fixtureCover);
      expect(
        await catalog.lookup({...metadataHeader, 'global_checksum': 'ffff'}),
        null,
      );
      expect(
        await catalog.lookup({...metadataHeader, 'rom_size': 1048576}),
        null,
      );
    },
  );

  test(
    'ambiguous headers stay unresolved and full ROM CRC can disambiguate',
    () async {
      await makeCatalog(site, ambiguous: true);
      final catalog = GameCatalog(
        source: site.uri,
        cache: Directory('${root.path}/cache'),
      );
      addTearDown(catalog.dispose);
      expect(await catalog.lookup(metadataHeader), null);
      expect(
        (await catalog.lookup(metadataHeader, crc32: '3358e30a'))!.title,
        'Pokémon Crystal Version',
      );
      expect(await catalog.lookup(metadataHeader, crc32: 'ffffffff'), null);
    },
  );

  test('damaged cover keeps metadata with a placeholder', () async {
    await makeCatalog(site, badCover: true);
    final catalog = GameCatalog(
      source: site.uri,
      cache: Directory('${root.path}/cache'),
    );
    addTearDown(catalog.dispose);
    final game = await catalog.lookup(metadataHeader);
    expect(game!.title, 'Pokémon Crystal Version');
    expect(game.coverBytes, null);
  });

  test(
    'hosted catalog requests stay on our host and persist for offline use',
    () async {
      await makeCatalog(site);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      final subscription = server.listen((request) async {
        paths.add(request.uri.path);
        expect(request.headers.value('Authorization'), null);
        request.response.add(
          await File('${site.path}${request.uri.path}').readAsBytes(),
        );
        await request.response.close();
      });
      final source = Uri.parse('http://127.0.0.1:${server.port}/');
      final cache = Directory('${root.path}/http-cache');
      final catalog = GameCatalog(source: source, cache: cache);
      expect((await catalog.lookup(metadataHeader))!.coverBytes, fixtureCover);
      expect(paths, [
        '/catalog/v1/manifest.json',
        '/catalog/v1/identity.json',
        '/catalog/v1/games/crystal.json',
        '/covers/crystal.png',
      ]);
      catalog.dispose();
      await server.close(force: true);
      await subscription.cancel();
      final offline = GameCatalog(source: source, cache: cache);
      addTearDown(offline.dispose);
      expect((await offline.lookup(metadataHeader))!.coverBytes, fixtureCover);
    },
  );

  test(
    'external paths and redirects cannot contact an artwork provider',
    () async {
      await makeCatalog(site);
      final manifest =
          jsonDecode(
                await File(
                  '${site.path}/catalog/v1/manifest.json',
                ).readAsString(),
              )
              as Json;
      manifest['identity']['path'] = 'https://example.invalid/data.json';
      await File(
        '${site.path}/catalog/v1/manifest.json',
      ).writeAsString(jsonEncode(manifest));
      final local = GameCatalog(
        source: site.uri,
        cache: Directory('${root.path}/cache'),
      );
      addTearDown(local.dispose);
      await expectLater(local.lookup(metadataHeader), throwsFormatException);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response.statusCode = 302;
        request.response.headers.set(
          'Location',
          'https://example.invalid/manifest.json',
        );
        request.response.close();
      });
      final remote = GameCatalog(
        source: Uri.parse('http://127.0.0.1:${server.port}/'),
        cache: Directory('${root.path}/redirect-cache'),
      );
      addTearDown(remote.dispose);
      await expectLater(
        remote.lookup(metadataHeader),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
