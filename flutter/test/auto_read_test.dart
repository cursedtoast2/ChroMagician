import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/backend.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'package:chromatic_pc_backup/catalog.dart';
import 'metadata_controller_test.dart' show FakeCatalog;
import 'catalog_test.dart' show metadataRecord, metadataHeader, fixtureCover;
import 'controller_test.dart' show FakeBackend, crystal;

class WatchingBackend extends FakeBackend {
  StreamController<BackendEvent>? monitor;
  final trace = <String>[];

  @override
  Stream<BackendEvent> watch(String port) {
    trace.add('watch');
    monitor = StreamController<BackendEvent>();
    return monitor!.stream;
  }

  @override
  Future<void> stopWatching() async {
    final previous = monitor;
    monitor = null;
    if (previous != null) {
      trace.add('stop');
      await previous.close();
    }
  }

  @override
  Stream<BackendEvent> run(List<String> arguments) {
    trace.add('transfer');
    return super.run(arguments);
  }
}

void main() {
  test(
    'app update releases discovery and can resume after a failed handoff',
    () async {
      final backend = WatchingBackend();
      final c = CartController(backend);
      addTearDown(() async {
        await c.stopDiscovery();
        c.dispose();
      });
      final started = c.startDiscovery();
      await Future<void>.delayed(Duration.zero);
      backend.monitor!.add({
        'event': 'cartridge_inspected',
        'cartridge': crystal,
      });
      await started;
      await c.pauseForAppUpdate();
      expect(backend.monitor, isNull);
      expect(c.title, 'PM_CRYSTAL');
      await c.refreshDevices();
      await c.inspect();
      expect(backend.monitor, isNull);
      final resumed = c.resumeAfterAppUpdate();
      await Future<void>.delayed(Duration.zero);
      backend.monitor!.add({
        'event': 'cartridge_inspected',
        'cartridge': crystal,
      });
      await resumed;
      expect(backend.trace.where((s) => s == 'watch').length, 2);
      c.busy = true;
      c.inspecting = false;
      await expectLater(c.pauseForAppUpdate(), throwsStateError);
      expect(
        backend.monitor,
        isNotNull,
        reason: 'Never interrupt a transfer for an app update.',
      );
    },
  );
  test(
    'one watcher automatically reads insertion, removal and replacement',
    () async {
      final backend = WatchingBackend();
      final c = CartController(backend);
      addTearDown(() async {
        await c.stopDiscovery();
        c.dispose();
      });
      final started = c.startDiscovery();
      await Future<void>.delayed(Duration.zero);
      backend.monitor!.add({'event': 'cartridge_unavailable'});
      await started;
      expect(c.cartridgeReady, false);
      expect(c.loadingGame, false);
      expect(c.error, null);

      backend.monitor!.add({
        'event': 'cartridge_inspected',
        'cartridge': crystal,
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.title, 'PM_CRYSTAL');
      expect(c.cartridgeReady, true);
      c.selectAction(CartAction.writeGame);
      c.chooseFile('/tmp/previous-cart.gbc');
      c.activity.add('Old transfer result');
      backend.monitor!.add({'event': 'cartridge_unavailable'});
      await Future<void>.delayed(Duration.zero);
      expect(c.cartridgeReady, false);
      expect(c.activity, isEmpty);
      backend.monitor!.add({
        'event': 'cartridge_inspected',
        'cartridge': {
          ...crystal,
          'title': 'POKEMON_GLD',
          'rom_writable': false,
        },
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.title, 'POKEMON_GLD');
      expect(c.canWriteGame, false);
      expect(c.action, CartAction.backupGame);
      expect(c.path, null);
      expect(backend.trace, ['watch']);
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'automatic reading releases USB before a transfer and resumes afterward',
    () async {
      final backend = WatchingBackend();
      final c = CartController(backend);
      addTearDown(() async {
        await c.stopDiscovery();
        c.dispose();
      });
      final started = c.startDiscovery();
      await Future<void>.delayed(Duration.zero);
      backend.monitor!.add({
        'event': 'cartridge_inspected',
        'cartridge': crystal,
      });
      await started;
      c.chooseFile('/tmp/cart.gbc');
      final transferred = c.transfer();
      await Future<void>.delayed(Duration.zero);
      expect(backend.trace, ['watch', 'stop', 'transfer', 'watch']);
      backend.monitor!.add({
        'event': 'cartridge_inspected',
        'cartridge': crystal,
      });
      await transferred;
      expect(c.finished, true);
      expect(c.title, 'PM_CRYSTAL');
      expect(c.activity, contains('Complete and verified'));
    },
  );
  for (final action in CartAction.values) {
    test(
      '${action.label} resumes monitoring without clearing the game or result',
      () async {
        final backend = WatchingBackend();
        var lookups = 0;
        final catalog = FakeCatalog()
          ..resolve = (header) async {
            lookups++;
            if (action == CartAction.backupGame && lookups > 1) return null;
            return GameMetadata(
              {...metadataRecord, 'title': header['title']},
              coverBytes: fixtureCover,
              system: 'gbc',
              region: 'NTSC-U',
            );
          };
        final c = CartController(backend, catalog: catalog);
        addTearDown(() async {
          await c.stopDiscovery();
          c.dispose();
        });
        final started = c.startDiscovery();
        await Future<void>.delayed(Duration.zero);
        backend.monitor!.add({
          'event': 'cartridge_inspected',
          'cartridge': {...crystal, ...metadataHeader},
        });
        await started;
        await Future<void>.delayed(Duration.zero);
        final displayedGame = c.game;
        expect(lookups, 1);
        var lostMetadata = false;
        void checkMetadata() {
          if (c.game != displayedGame) lostMetadata = true;
        }

        c.addListener(checkMetadata);
        c.selectAction(action);
        c.chooseFile('/tmp/transfer-file');
        backend.transfer = () => Stream.fromIterable([
          if (action != CartAction.writeGame)
            {
              'event': 'cartridge_detected',
              'cartridge': Map.of(crystal)
                ..remove('rom_writable')
                ..['has_rtc'] = true,
            },
          if (action == CartAction.backupGame)
            {'event': 'artifact_verified', 'kind': 'rom', 'crc32': '12345678'},
          {'event': 'complete'},
        ]);
        final transferred = c.transfer();
        await Future<void>.delayed(Duration.zero);
        expect(c.game, same(displayedGame));
        expect(c.cartridgeReady, true);
        expect(c.loadingGame, false);
        expect(c.finished, true);
        expect(c.canWriteGame, true);
        expect(
          c.cartridge!['global_checksum'],
          metadataHeader['global_checksum'],
        );
        expect(c.game!.coverBytes, same(fixtureCover));
        expect(c.game!.releaseDate, 'Jul 30, 2001');
        expect(c.game!.stars, 4.5);
        expect(lostMetadata, false);
        if (action == CartAction.writeGame) c.removeListener(checkMetadata);
        final next = action == CartAction.writeGame
            ? {
                ...crystal,
                ...metadataHeader,
                'title': 'POKEMON_GLD',
                'cartridge_type': 0x1b,
              }
            : {...crystal, ...metadataHeader};
        backend.monitor!.add({
          'event': 'cartridge_inspected',
          'cartridge': next,
        });
        await transferred;
        await Future<void>.delayed(Duration.zero);
        expect(c.loadingGame, false);
        expect(c.finished, true);
        expect(c.phase, 'Complete and verified');
        expect(c.canWriteGame, true);
        expect(c.title, next['title']);
        expect(lookups, action.isGame ? 2 : 1);
        if (action != CartAction.writeGame) expect(c.game, same(displayedGame));
        expect(lostMetadata, false);
        c.removeListener(checkMetadata);
      },
    );
  }
}
