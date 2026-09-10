import 'dart:async';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/app.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'package:chromatic_pc_backup/catalog.dart';
import 'catalog_test.dart' show metadataRecord;

import 'controller_test.dart' show FakeBackend, crystal;

class FakeFileSelector extends FileSelectorPlatform {
  final selection = Completer<String?>();
  bool? saving;
  String? buttonText;
  String? suggestedName;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    saving = false;
    buttonText = confirmButtonText;
    final path = await selection.future;
    return path == null ? null : XFile(path);
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    saving = true;
    buttonText = options.confirmButtonText;
    suggestedName = options.suggestedName;
    final path = await selection.future;
    return path == null ? null : FileSaveLocation(path);
  }
}

void main() {
  for (final change in ['cancel', 'disconnect', 'sd swap', 'cart swap']) {
    testWidgets('SD backup confirmation ignores $change', (tester) async {
      tester.view.physicalSize = const Size(1180, 980);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend();
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..cartridge = Map.of(crystal)
        ..sdPresent = true;
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      await tester.tap(find.byKey(const ValueKey('cart-sd-action')));
      await tester.pumpAndSettle();
      expect(backend.calls, isEmpty);
      if (change == 'disconnect') c.port = null;
      if (change == 'sd swap') c.sdGeneration++;
      if (change == 'cart swap') c.cartridge = {...crystal, 'title': 'RED'};
      await tester.tap(find.text(change == 'cancel' ? 'Cancel' : 'Back up'));
      await tester.pumpAndSettle();
      expect(backend.calls, isEmpty);
      expect(c.busy, false);
      expect(tester.takeException(), null);
    });
  }
  for (final action in [CartAction.backupGame, CartAction.backupSave]) {
    testWidgets(
      '${action.label} offers direct SD backup only with a card inserted',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 980);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = FakeBackend();
        final c = CartController(backend)
          ..port = '/dev/ttyTEST'
          ..cartridge = Map.of(crystal)
          ..game = const GameMetadata(
            metadataRecord,
            releaseName: 'Pokemon - Crystal (Japan) (Rev 1)',
          );
        c.selectAction(action);
        addTearDown(c.dispose);
        await tester.pumpWidget(ChromaticApp(controller: c));
        final sd = find.byKey(const ValueKey('cart-sd-action'));
        expect(tester.widget<FilledButton>(sd).onPressed, null);
        await tester.tap(sd);
        await tester.pump();
        expect(backend.calls, isEmpty);
        c.sdPresent = true;
        await tester.pumpWidget(
          ChromaticApp(key: const ValueKey('with-sd'), controller: c),
        );
        expect(tester.widget<FilledButton>(sd).onPressed, isNotNull);
        await tester.tap(sd);
        await tester.pumpAndSettle();
        expect(backend.calls, isEmpty);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Back up'));
        await tester.pumpAndSettle();
        expect(backend.calls.single, [
          action.isGame ? '--sd-backup-rom' : '--sd-backup-sav',
          '/CHROMAGIC/BACKUPS/Pokemon - Crystal (Japan) (Rev 1).${action.isGame ? 'gbc' : 'sav'}',
          '--port',
          '/dev/ttyTEST',
          '--boot-wait-ms',
          '750',
          '--timeout',
          '1800',
        ]);
        expect(c.finished, true);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), null);
      },
    );
  }

  late FakeFileSelector picker;
  setUp(() {
    final original = FileSelectorPlatform.instance;
    addTearDown(() => FileSelectorPlatform.instance = original);
  });

  for (final action in CartAction.values) {
    testWidgets('${action.label} starts when its system dialog is confirmed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1180, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      picker = FakeFileSelector();
      FileSelectorPlatform.instance = picker;
      final backend = FakeBackend();
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..cartridge = Map.of(crystal)
        ..game = const GameMetadata(
          metadataRecord,
          releaseName: 'Pokemon - Crystal Version (USA, Europe) (Rev 1)',
        );
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      final path = '/tmp/game with spaces.${action.isGame ? 'gbc' : 'sav'}';
      await tester.tap(find.widgetWithText(TextButton, action.label));
      await tester.pump();
      expect(backend.calls, isEmpty);
      expect(c.action, action);
      await tester.tap(find.byKey(const ValueKey('cart-file-action')));
      await tester.pump();
      for (final button in tester.widgetList<TextButton>(
        find.byType(TextButton),
      )) {
        expect(button.onPressed, isNull);
      }
      expect(picker.saving, !action.writes);
      expect(picker.buttonText, action.label);
      if (!action.writes) {
        expect(
          picker.suggestedName,
          'Pokemon - Crystal Version (USA, Europe) (Rev 1).${action.isGame ? 'gbc' : 'sav'}',
        );
      }
      picker.selection.complete(path);
      await tester.pumpAndSettle();
      final transfers = backend.calls.where(
        (args) => !args.contains('--inspect'),
      );
      expect(transfers.single, [
        action.flag,
        path,
        '--port',
        '/dev/ttyTEST',
        if (action.writes) '--yes' else '--force',
      ]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Browse'), findsNothing);
      expect(c.finished, true);
    });
  }

  testWidgets('cancelled or disconnected dialog never starts a transfer', (
    tester,
  ) async {
    picker = FakeFileSelector();
    FileSelectorPlatform.instance = picker;
    final backend = FakeBackend();
    final c = CartController(backend)
      ..port = '/dev/ttyTEST'
      ..cartridge = Map.of(crystal)
      ..selectAction(CartAction.writeGame);
    addTearDown(c.dispose);
    await tester.pumpWidget(ChromaticApp(controller: c));
    await tester.tap(find.byKey(const ValueKey('cart-file-action')));
    picker.selection.complete(null);
    await tester.pumpAndSettle();
    expect(backend.calls, isEmpty);

    picker = FakeFileSelector();
    FileSelectorPlatform.instance = picker;
    await tester.tap(find.byKey(const ValueKey('cart-file-action')));
    backend.connected = [];
    await c.refreshDevices();
    picker.selection.complete('/tmp/game.gbc');
    await tester.pumpAndSettle();
    expect(backend.calls, isEmpty);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets(
    'restore automatically includes the clock file without a toggle',
    (tester) async {
      const path = '/tmp/game.sav';
      picker = FakeFileSelector();
      FileSelectorPlatform.instance = picker;
      final backend = FakeBackend();
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..cartridge = Map.of(crystal)
        ..selectAction(CartAction.restoreSave);
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Include matching clock file'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cart-file-action')));
      picker.selection.complete(path);
      await tester.pumpAndSettle();
      expect(backend.calls.single, isNot(contains('--save-only')));
      expect(c.finished, true);
    },
  );
}
