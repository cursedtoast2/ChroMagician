import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/catalog.dart';
import 'catalog_test.dart' show metadataHeader;

void main() {
  final site = Platform.environment['CHROMATIC_TEST_CATALOG'];
  test(
    'Yellow resolves by exact header, FlashGBX hash and full ROM checksum',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'chromagician-yellow-',
      );
      addTearDown(() => cache.delete(recursive: true));
      final catalog = GameCatalog(source: Directory(site!).uri, cache: cache);
      addTearDown(catalog.dispose);
      const header = <String, dynamic>{
        'title': 'POKEMON YEL',
        'color': true,
        'rom_size': 1048576,
        'global_checksum': '047c',
        'header_checksum': 151,
        'rom_version': 0,
      };
      for (final hash in [null, '94bf8a1dce57267bc7e3063627c9f8977ef77e38']) {
        final game = await catalog.lookup({...header, 'header_sha1': ?hash});
        expect(game?.title, 'Pokémon Yellow Version: Special Pikachu Edition');
        expect(
          game?.releaseName,
          'Pokemon - Yellow Version - Special Pikachu Edition (USA, Europe) (CGB+SGB Enhanced)',
        );
        expect(game?.coverBytes?.length, greaterThan(10000));
      }
      final game = await catalog.lookup(header, crc32: '7d527d62');
      expect(game?.title, 'Pokémon Yellow Version: Special Pikachu Edition');
    },
    skip: site == null
        ? 'Set CHROMATIC_TEST_CATALOG to the generated catalog.'
        : false,
  );
  test(
    'generated catalog supplies real Crystal and Gold records and artwork',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'chromatic-real-catalog-',
      );
      addTearDown(() => cache.delete(recursive: true));
      final catalog = GameCatalog(source: Directory(site!).uri, cache: cache);
      addTearDown(catalog.dispose);
      final crystal = await catalog.lookup(metadataHeader);
      expect(crystal!.title, 'Pokémon Crystal Version');
      expect(crystal.developers, contains('Game Freak'));
      expect(crystal.releaseDate, 'Jul 30, 2001');
      expect(crystal.coverBytes!.length, greaterThan(10000));
      expect(crystal.stars, inInclusiveRange(0.0, 5.0));
      final gold = await catalog.lookup({
        ...metadataHeader,
        'title': 'POKEMON_GLD',
        'global_checksum': '682d',
        'header_checksum': 75,
        'rom_version': 0,
      });
      expect(gold!.title, 'Pokémon Gold Version');
      expect(gold.coverBytes!.length, greaterThan(10000));
      expect(gold.stars, inInclusiveRange(0.0, 5.0));
    },
    skip: site == null
        ? 'Set CHROMATIC_TEST_CATALOG to a generated site directory.'
        : false,
  );
  test(
    'Japanese header identities load regional art and metadata from the packaged catalog',
    () async {
      final root = Directory(site!);
      final cache = await Directory.systemTemp.createTemp(
        'chromatic-japanese-catalog-',
      );
      addTearDown(() => cache.delete(recursive: true));
      final catalog = GameCatalog(source: root.uri, cache: cache);
      addTearDown(catalog.dispose);
      final manifest =
          jsonDecode(
                await File(
                  '${root.path}/catalog/v1/manifest.json',
                ).readAsString(),
              )
              as Json;
      final identity =
          jsonDecode(
                await File(
                  '${root.path}/${manifest['identity']['path']}',
                ).readAsString(),
              )
              as Json;
      final cases = {
        'Pocket Monsters - Aka': 'Pokémon Red Version',
        'Super Mario Land 2 - 6-tsu no Kinka':
            'Super Mario Land 2: 6 Golden Coins',
        'Zelda no Densetsu - Yume o Miru Shima':
            "The Legend of Zelda: Link's Awakening",
        'Heiankyou Alien': 'Heiankyo Alien',
        'Dragon Quest I & II': 'Dragon Warrior I & II',
        'Dragon Quest Monsters 2 - Maruta no Fushigina Kagi - Iru no Bouken':
            "Dragon Warrior Monsters 2: Tara's Adventure",
      };
      for (final item in cases.entries) {
        final match = (identity['header_sha1'] as Json).entries.firstWhere(
          (entry) => (entry.value as List).any(
            (r) =>
                r['region'] == 'NTSC-J' &&
                (r['release_name'] as String).startsWith('${item.key} ('),
          ),
        );
        final row = (match.value as List).cast<Json>().firstWhere(
          (r) => r['region'] == 'NTSC-J',
        );
        final game = await catalog.lookup({
          ...metadataHeader,
          'title': 'RAW_TITLE',
          'color': row['system'] == 'gbc',
          'rom_size': row['rom_size'],
          'header_sha1': match.key,
        });
        expect(game?.title, item.value, reason: item.key);
        expect(game?.region, 'NTSC-J', reason: item.key);
        expect(game?.coverBytes?.length, greaterThan(10000), reason: item.key);
      }
    },
    skip: site == null
        ? 'Set CHROMATIC_TEST_CATALOG to the generated catalog.'
        : false,
  );
  test(
    'B-MAXHIKARI resolves the Japanese title, date and box art by header and hash',
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'chromatic-bomberman-catalog-',
      );
      addTearDown(() => cache.delete(recursive: true));
      final catalog = GameCatalog(source: Directory(site!).uri, cache: cache);
      addTearDown(catalog.dispose);
      const header = <String, dynamic>{
        'title': 'B-MAXHIKARI',
        'color': true,
        'cartridge_type': 0x1b,
        'rom_size': 2097152,
        'save_size': 8192,
        'global_checksum': '4220',
        'header_checksum': 0x56,
        'rom_version': 0,
      };
      for (final input in [
        header,
        {...header, 'header_sha1': 'b0d2a01307e2a193354237fd634ebad4b90691e0'},
      ]) {
        final game = await catalog.lookup(input);
        expect(game?.title, 'Bomberman Max: Hikari no Yuusha');
        expect(game?.releaseDate, 'Dec 17, 1999');
        expect(game?.region, 'NTSC-J');
        expect(game?.coverBytes?.length, 510339);
        expect(game?.coverBytes?.take(4), [0x89, 0x50, 0x4e, 0x47]);
        expect(game?.summary, isNotEmpty);
      }
      final dark = await catalog.lookup({
        ...header,
        'title': 'B-MAXYAMI',
        'header_sha1': '98f83e660e53d242f4ea423dce355b9ead9135fe',
      });
      expect(dark?.title, 'Bomberman Max: Yami no Senshi');
      expect(dark?.coverBytes?.length, 481066);
      final blue = await catalog.lookup({
        ...header,
        'title': 'B-MAX-BLUE',
        'header_sha1': '2e2aa202523ad44e1efd8c07b71c7b08b09adcc4',
      });
      expect(blue?.title, 'Bomberman Max: Blue Champion');
      expect(blue?.region, 'NTSC-U');
    },
    skip: site == null
        ? 'Set CHROMATIC_TEST_CATALOG to the generated catalog.'
        : false,
  );
  test(
    "Link's Awakening DX supplies the canonical filename for each revision",
    () async {
      final cache = await Directory.systemTemp.createTemp(
        'chromatic-zelda-name-',
      );
      addTearDown(() => cache.delete(recursive: true));
      final catalog = GameCatalog(source: Directory(site!).uri, cache: cache);
      addTearDown(catalog.dispose);
      const revisions = [
        ('c1fa639c4081ee38d168bd4e59d9358e6ac333b3', 'e3fd', 0x3c, ''),
        ('acc0671e8b4602078ed52c5cfa036ec616ac1c74', '2735', 0x3b, ' (Rev 1)'),
        ('ed389348c7a0530a87e986d601a49b742435d58d', '0135', 0x0e, ' (Rev 2)'),
      ];
      for (var i = 0; i < revisions.length; i++) {
        final (hash, checksum, headerChecksum, revision) = revisions[i];
        final header = {
          'title': 'ZELDA',
          'color': true,
          'rom_size': 1048576,
          'global_checksum': checksum,
          'header_checksum': headerChecksum,
          'rom_version': i,
        };
        for (final input in [
          header,
          {...header, 'header_sha1': hash},
        ]) {
          final game = await catalog.lookup(input);
          expect(
            game?.releaseName,
            "Legend of Zelda, The - Link's Awakening DX (USA, Europe)$revision (SGB Enhanced) (GB Compatible)",
          );
        }
      }
    },
    skip: site == null
        ? 'Set CHROMATIC_TEST_CATALOG to the generated catalog.'
        : false,
  );
}
