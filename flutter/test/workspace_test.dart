import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/app.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'package:chromatic_pc_backup/catalog.dart';
import 'package:chromatic_pc_backup/main.dart' show defaultWindowSize;
import 'controller_test.dart' show FakeBackend, crystal;
import 'catalog_test.dart' show metadataRecord, fixtureCover;
import 'metadata_controller_test.dart' show FakeCatalog;

void main() {
  for (final sd in [false, true]) {
    testWidgets('disconnect hides completed ${sd ? 'SD' : 'cart'} progress', (
      tester,
    ) async {
      tester.view.physicalSize = defaultWindowSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend();
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..cartridge = crystal
        ..sdPresent = true
        ..showingSd = sd;
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      if (sd) {
        await c.sdCommand(['--sd-get', '/save.sav', '--file', '/tmp/save.sav']);
      } else {
        c.chooseFile('/tmp/save.sav');
        await c.transfer();
      }
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        find.text(sd ? 'Complete' : 'Complete and verified'),
        findsOneWidget,
      );
      backend.connected = [];
      await c.refreshDevices();
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Complete'), findsNothing);
      expect(find.text('Complete and verified'), findsNothing);
      expect(find.text('100%'), findsNothing);
      expect(find.text('Chromatic disconnected'), findsNothing);
      expect(tester.takeException(), null);
    });
  }

  testWidgets(
    'ROM writing requires physical writability; save restore remains available',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend();
      final c = CartController(backend)..port = '/dev/ttyTEST';
      addTearDown(c.dispose);
      for (final writable in [null, false, true]) {
        c.cartridge = {...crystal, 'rom_writable': writable};
        await tester.pumpWidget(
          ChromaticApp(key: ValueKey(writable), controller: c),
        );
        await tester.pumpAndSettle();
        final tab = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Write Homebrew'),
        );
        expect(tab.onPressed != null, writable == true);
        expect(
          find.text('Rewritable'),
          writable == true ? findsOneWidget : findsNothing,
        );
        c.selectAction(CartAction.writeGame);
        expect(
          c.action,
          writable == true ? CartAction.writeGame : CartAction.backupGame,
        );
        c.action = CartAction.writeGame;
        c.chooseFile('/tmp/game.gbc');
        await tester.pump();
        final button = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Write Homebrew'),
        );
        expect(button.onPressed != null, writable == true);
        if (writable != true) {
          await c.transfer();
          expect(backend.calls, isEmpty);
        }
        c.selectAction(CartAction.restoreSave);
        c.chooseFile('/tmp/game.sav');
        expect(c.canStart, true);
        c.selectAction(CartAction.backupGame);
      }
    },
  );

  testWidgets('enabled mode with no game shows the insertion prompt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = FakeBackend()
      ..inspection = () => Stream.fromIterable([
        {'event': 'device_status', 'enabled': true, 'cartridge_present': false},
        {'event': 'cartridge_unavailable'},
      ]);
    final c = CartController(backend);
    addTearDown(c.dispose);
    await c.refreshDevices();
    await tester.pumpWidget(ChromaticApp(controller: c));
    await tester.pumpAndSettle();
    expect(c.port, isNotNull);
    expect(c.cartridgeReady, false);
    expect(c.error, null);
    expect(find.text('Insert a game cartridge'), findsOneWidget);
    expect(find.textContaining('Nintendo logo'), findsNothing);
    expect(find.text('Your next adventure'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byTooltip('Refresh cartridge'), findsNothing);
    for (final action in CartAction.values) {
      expect(find.text(action.label), findsNothing);
    }
    expect(find.textContaining('Enable C. MAGICIAN'), findsNothing);
  });

  testWidgets(
    'automatic artwork and metadata fit both desktop sizes with an empty idle status background',
    (tester) async {
      final backend = FakeBackend();
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..cartridge = {...crystal, 'cart_size': 4194304}
        ..game = GameMetadata(
          metadataRecord,
          coverBytes: fixtureCover,
          region: 'NTSC-U',
          system: 'gbc',
        );
      addTearDown(c.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      for (final size in [defaultWindowSize, const Size(820, 660)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(ChromaticApp(controller: c));
        await tester.pumpAndSettle();
        expect(find.text('Pokémon Crystal Version'), findsOneWidget);
        expect(
          find.text('Game Freak · Nintendo · Jul 30, 2001'),
          findsOneWidget,
        );
        expect(find.text(metadataRecord['summary'] as String), findsOneWidget);
        expect(find.byIcon(Icons.star_rounded), findsNWidgets(4));
        expect(find.byIcon(Icons.star_half_rounded), findsOneWidget);
        expect(
          tester.getTopLeft(find.byIcon(Icons.star_rounded).first).dy,
          greaterThan(
            tester
                .getBottomLeft(
                  find.text('Game Freak · Nintendo · Jul 30, 2001'),
                )
                .dy,
          ),
        );
        expect(find.byType(Image), findsOneWidget);
        expect(
          tester.getTopLeft(find.widgetWithText(TextButton, 'Back up game')).dy,
          greaterThan(tester.getBottomLeft(find.byType(Image).last).dy),
        );
        expect(find.byKey(const ValueKey('transfer-panel')), findsOneWidget);
        if (size == defaultWindowSize) {
          final panel = tester.getRect(
            find.byKey(const ValueKey('transfer-panel')),
          );
          final viewport = tester.getRect(find.byType(SingleChildScrollView));
          expect(panel.top, greaterThanOrEqualTo(viewport.top));
          expect(panel.bottom, lessThanOrEqualTo(viewport.bottom));
          expect(
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position
                .maxScrollExtent,
            0,
          );
        }
        expect(find.text('Ready when you are'), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.text('ChroMagician'), findsNothing);
        expect(find.text('Select game'), findsNothing);
        expect(find.text('4 MiB CART'), findsOneWidget);
        expect(find.text('32 KiB SAVE'), findsNothing);
        expect(tester.takeException(), null);
      }
      tester.view.physicalSize = defaultWindowSize;
      c.sdPresent = true;
      await tester.pumpAndSettle();
      final events = StreamController<Map<String, dynamic>>();
      backend.transfer = () => events.stream;
      c.chooseFile('/tmp/progress-check.gbc');
      final transfer = c.transfer();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester.getBottomLeft(find.byKey(const ValueKey('transfer-panel'))).dy,
        lessThanOrEqualTo(
          tester.getBottomLeft(find.byType(SingleChildScrollView)).dy,
        ),
      );
      events.add({'event': 'progress', 'received': 256, 'total': 1024});
      await tester.pump();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.25,
      );
      events.add({'event': 'complete'});
      await events.close();
      await transfer;
      await tester.pumpAndSettle();
      expect(find.text('Complete and verified'), findsOneWidget);
      c.selectAction(CartAction.backupSave);
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );
  testWidgets(
    'tabs select operations without starting them at both desktop sizes',
    (tester) async {
      final backend = FakeBackend();
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..cartridge = Map.of(crystal);
      addTearDown(c.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      for (final size in [const Size(1180, 850), const Size(820, 660)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(ChromaticApp(controller: c));
        await tester.pumpAndSettle();
        expect(tester.takeException(), null);
        for (final action in CartAction.values) {
          c.selectAction(action);
          await tester.pumpAndSettle();
          final buttons = tester.widgetList<TextButton>(
            find.byType(TextButton),
          );
          expect(buttons.length, 4);
          for (final button in buttons) {
            expect(button.onPressed, isNotNull);
          }
          final selected = tester.widget<TextButton>(
            find.byKey(ValueKey('cart-tab-${action.name}')),
          );
          expect(selected.style!.foregroundColor!.resolve({}), lime);
          final widths = CartAction.values.map(
            (item) => tester
                .getSize(find.widgetWithText(TextButton, item.label))
                .width,
          );
          for (final width in widths) {
            expect(width, closeTo(widths.first, 0.5));
          }
          expect(find.widgetWithText(TextButton, action.label), findsOneWidget);
          expect(
            find.byKey(const ValueKey('cart-file-action')),
            findsOneWidget,
          );
          expect(tester.takeException(), null);
        }
      }
      expect(find.text('Browse'), findsNothing);
      expect(find.byType(TextButton), findsNWidgets(4));
      expect(find.text('Include matching clock file'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(backend.calls, isEmpty);
    },
  );

  testWidgets(
    'controls stay hidden through discovery, loading and disconnect',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend()..connected = [];
      final metadata = Completer<GameMetadata?>();
      final catalog = FakeCatalog()..resolve = (_) => metadata.future;
      final c = CartController(backend, catalog: catalog);
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      expect(find.text('Loading'), findsOneWidget);
      expect(tester.getCenter(find.text('Loading')).dx, 590);
      expect(find.byType(TextButton), findsNothing);
      await c.refreshDevices();
      await tester.pumpAndSettle();
      expect(find.text('Loading'), findsNothing);
      expect(find.text('Connect your Chromatic'), findsNWidgets(2));
      expect(find.byTooltip('Refresh cartridge'), findsNothing);
      for (final action in CartAction.values) {
        expect(find.text(action.label), findsNothing);
      }

      final header = StreamController<Map<String, dynamic>>();
      backend.connected = ['/dev/ttyTEST'];
      backend.inspection = () => header.stream;
      final scan = c.refreshDevices();
      await tester.pump();
      await tester.pump();
      expect(find.text('Loading'), findsOneWidget);
      expect(find.text('Your next adventure'), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      header.add({'event': 'cartridge_inspected', 'cartridge': crystal});
      await header.close();
      await scan;
      await tester.pump();
      expect(c.inspecting, false);
      expect(find.text('Loading'), findsOneWidget);
      metadata.complete(const GameMetadata(metadataRecord));
      await tester.pumpAndSettle();
      expect(find.text('Loading'), findsNothing);
      expect(find.text('Pokémon Crystal Version'), findsOneWidget);
      expect(find.byType(TextButton), findsNWidgets(4));

      backend.connected = [];
      await c.refreshDevices();
      await tester.pumpAndSettle();
      expect(find.text('Loading'), findsNothing);
      expect(find.text('Pokémon Crystal Version'), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      for (final action in CartAction.values) {
        expect(find.text(action.label), findsNothing);
      }
    },
  );
}
