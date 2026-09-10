import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/catalog.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'controller_test.dart' show FakeBackend;
import 'catalog_test.dart' show metadataRecord, fixtureCover;

class FakeCatalog extends CartCatalog {
  Future<GameMetadata?> Function(Json header) resolve = (_) async =>
      const GameMetadata(metadataRecord);
  @override
  Future<GameMetadata?> lookup(Json header, {String? crc32}) => resolve(header);
}

void main() {
  test(
    'failed or unmatched metadata refresh keeps the resolved game and artwork',
    () async {
      final displayed = GameMetadata(
        metadataRecord,
        coverBytes: fixtureCover,
        releaseName: 'Pokemon - Crystal Version (USA, Europe) (Rev 1)',
      );
      final catalog = FakeCatalog()..resolve = (_) async => displayed;
      final c = CartController(FakeBackend(), catalog: catalog);
      addTearDown(c.dispose);
      await c.refreshDevices();
      await c.refreshMetadata();
      final filename = c.suggestedName;
      for (final fail in [false, true]) {
        catalog.resolve = (_) async {
          if (fail) throw const FormatException('catalog unavailable');
          return null;
        };
        await c.refreshMetadata(crc32: 'unlisted');
        expect(c.game, same(displayed));
        expect(c.game!.coverBytes, same(fixtureCover));
        expect(c.suggestedName, filename);
        expect(c.metadataLoading, false);
      }
    },
  );

  test(
    'uncatalogued games use their header title and blank headers use Unknown game',
    () async {
      final c = CartController(
        FakeBackend(),
        catalog: FakeCatalog()..resolve = (_) async => null,
      );
      addTearDown(c.dispose);
      await c.refreshDevices();
      await c.refreshMetadata();
      expect(c.title, 'PM_CRYSTAL');
      for (final title in ['', '   ']) {
        c.cartridge = {...c.cartridge!, 'title': title};
        expect(c.title, 'Unknown game');
      }
      c.cartridge = {...c.cartridge!, 'title': ' TETRIS '};
      expect(c.title, 'TETRIS');
    },
  );

  test(
    'catalog lookup updates title without adding a cartridge operation',
    () async {
      final backend = FakeBackend();
      final c = CartController(backend, catalog: FakeCatalog());
      addTearDown(c.dispose);
      await c.refreshDevices();
      await c.refreshMetadata();
      expect(c.title, 'Pokémon Crystal Version');
      expect(c.rawTitle, 'PM_CRYSTAL');
      expect(backend.calls.length, 1);
      expect(backend.calls.single, contains('--inspect'));
    },
  );

  test(
    'slow lookup cannot block cartridge tools or restore art after disconnect',
    () async {
      final pending = Completer<GameMetadata?>();
      final catalog = FakeCatalog()..resolve = (_) => pending.future;
      final backend = FakeBackend();
      final c = CartController(backend, catalog: catalog);
      addTearDown(c.dispose);
      await c.refreshDevices();
      c.chooseFile('/tmp/backup.gb');
      expect(c.metadataLoading, true);
      expect(c.busy, false);
      expect(c.canStart, true);
      backend.connected = [];
      await c.refreshDevices();
      pending.complete(const GameMetadata(metadataRecord));
      await Future<void>.delayed(Duration.zero);
      expect(c.game, null);
      expect(c.cartridge, null);
      expect(c.metadataLoading, false);
    },
  );

  test('catalog failure leaves raw title and transfer state intact', () async {
    final catalog = FakeCatalog()
      ..resolve = (_) async => throw const FormatException('bad catalog');
    final c = CartController(FakeBackend(), catalog: catalog);
    addTearDown(c.dispose);
    await c.refreshDevices();
    await c.refreshMetadata();
    expect(c.game, null);
    expect(c.title, 'PM_CRYSTAL');
    expect(c.error, null);
    c.chooseFile('/tmp/backup.gb');
    expect(c.canStart, true);
  });

  test(
    'older lookup cannot overwrite metadata after a cartridge refresh',
    () async {
      final old = Completer<GameMetadata?>();
      final catalog = FakeCatalog()..resolve = (_) => old.future;
      final c = CartController(FakeBackend(), catalog: catalog);
      addTearDown(c.dispose);
      await c.refreshDevices();
      catalog.resolve = (_) async =>
          GameMetadata({...metadataRecord, 'title': 'A different game'});
      await c.inspect();
      await c.refreshMetadata();
      old.complete(const GameMetadata(metadataRecord));
      await Future<void>.delayed(Duration.zero);
      expect(c.title, 'A different game');
    },
  );
}
