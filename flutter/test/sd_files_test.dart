import 'dart:async';
import 'package:chromatic_pc_backup/app.dart';
import 'package:chromatic_pc_backup/backend.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'controller_test.dart' show FakeBackend;
import 'file_actions_test.dart' show FakeFileSelector;

const entries = [
  {'name': 'CHROMATIC', 'directory': true, 'size': 0},
  {'name': 'ボンバーマン.gbc', 'directory': false, 'size': 2097152},
];
void main() {
  for (final confirm in [false, true]) {
    testWidgets(
      'folder deletion ${confirm ? 'confirms contents' : 'can be cancelled'}',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 980);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = FakeBackend();
        final c = CartController(backend)
          ..port = '/dev/ttyTEST'
          ..sdPresent = true
          ..showingSd = true
          ..sdEntries = [entries.first];
        addTearDown(c.dispose);
        await tester.pumpWidget(ChromaticApp(controller: c));
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(backend.calls, isEmpty);
        expect(
          find.text('This deletes the folder and everything inside it.'),
          findsOneWidget,
        );
        await tester.tap(
          find.widgetWithText(TextButton, confirm ? 'Delete' : 'Cancel'),
        );
        await tester.pumpAndSettle();
        if (confirm) {
          expect(backend.calls.single.take(2), [
            '--sd-delete-tree',
            '/CHROMATIC',
          ]);
        } else {
          expect(backend.calls, isEmpty);
        }
        expect(tester.takeException(), null);
      },
    );
  }
  testWidgets(
    'SD files are accessible without a game and browsing leaves progress empty',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 980);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend()
        ..transfer = () => Stream.fromIterable([
          {'event': 'sd_list', 'path': '/', 'entries': entries},
          {'event': 'complete'},
        ]);
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..pcModeEnabled = true
        ..sdPresent = true;
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      expect(find.text('SD Card'), findsOneWidget);
      expect(find.text('Back up game'), findsNothing);
      await tester.tap(find.text('SD Card'));
      await tester.pumpAndSettle();
      expect(c.showingSd, true);
      expect(find.text('ボンバーマン.gbc'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(c.hasTransfer, false);
      expect(backend.calls.single, contains('--sd-list'));
      expect(tester.takeException(), null);
      await tester.tap(find.text('Cartridge'));
      await tester.pumpAndSettle();
      expect(find.text('Insert a game cartridge'), findsOneWidget);
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'returning from an SD ${fails ? 'failure' : 'transfer'} to an empty cartridge slot shows the insert prompt',
      (tester) async {
        tester.view.physicalSize = const Size(1180, 980);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = FakeBackend()
          ..transfer = () => fails
              ? Stream.error(const BackendFailure('device_error', 'SD error'))
              : Stream.fromIterable([
                  {
                    'event': 'progress',
                    'phase': 'sd_write',
                    'completed': 1024,
                    'total': 1024,
                  },
                  {'event': 'complete'},
                ]);
        final c = CartController(backend)
          ..port = '/dev/ttyTEST'
          ..pcModeEnabled = true
          ..sdPresent = true
          ..showingSd = true;
        addTearDown(c.dispose);
        await tester.pumpWidget(ChromaticApp(controller: c));
        await c.sdCommand([
          '--sd-put',
          '/example.gb',
          '--file',
          '/tmp/example.gb',
        ]);
        await tester.pumpAndSettle();
        expect(c.hasTransfer, true);

        await tester.tap(find.text('Cartridge'));
        await tester.pumpAndSettle();
        expect(find.text('Insert a game cartridge'), findsOneWidget);
        expect(find.text('Unknown game'), findsNothing);
        expect(find.text('Back up game'), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(c.hasTransfer, false);
        expect(c.error, null);
        expect(tester.takeException(), null);
      },
    );
  }

  testWidgets(
    'SD upload starts at native picker confirmation and uses one progress bar',
    (tester) async {
      final previous = FileSelectorPlatform.instance;
      addTearDown(() => FileSelectorPlatform.instance = previous);
      final picker = FakeFileSelector();
      FileSelectorPlatform.instance = picker;
      final stream = StreamController<BackendEvent>();
      final backend = FakeBackend()..transfer = () => stream.stream;
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..sdPresent = true
        ..showingSd = true;
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(820, 660);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ChromaticApp(controller: c));
      await tester.tap(find.text('Copy to SD card'));
      await tester.pump();
      expect(backend.calls, isEmpty);
      picker.selection.complete('/tmp/ボンバーマン.gbc');
      await tester.pump();
      await tester.pump();
      expect(backend.calls.single.take(4), [
        '--sd-put',
        '/ボンバーマン.gbc',
        '--file',
        '/tmp/ボンバーマン.gbc',
      ]);
      stream.add({
        'event': 'progress',
        'phase': 'sd_write',
        'completed': 1024,
        'total': 2048,
      });
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Copying to SD card'), findsOneWidget);
      expect(tester.takeException(), null);
      stream.add({'event': 'sd_list', 'path': '/', 'entries': entries});
      stream.add({'event': 'complete'});
      await stream.close();
      await tester.pumpAndSettle();
      expect(c.finished, true);
      expect(find.text('ボンバーマン.gbc'), findsOneWidget);
    },
  );

  testWidgets('an SD picker cannot authorize a reconnected device', (
    tester,
  ) async {
    final previous = FileSelectorPlatform.instance;
    addTearDown(() => FileSelectorPlatform.instance = previous);
    final picker = FakeFileSelector();
    FileSelectorPlatform.instance = picker;
    final backend = FakeBackend();
    final c = CartController(backend)
      ..port = '/dev/ttyTEST'
      ..sdPresent = true
      ..showingSd = true;
    addTearDown(c.dispose);
    await tester.pumpWidget(ChromaticApp(controller: c));
    await tester.tap(find.text('Copy to SD card'));
    await tester.pump();
    backend.connected = [];
    await c.refreshDevices();
    c.port = '/dev/ttyTEST';
    c.sdPresent = true;
    picker.selection.complete('/tmp/example.gbc');
    await tester.pumpAndSettle();
    expect(backend.calls, isEmpty);
  });

  test('SD errors do not tell users to change cartridge mode', () {
    expect(
      CartController.friendlyError(
        const BackendFailure(
          'device_error',
          'device failed: SD card: ESP_ERR_INVALID_STATE op=7 errno=17',
        ),
      ),
      isNot(contains('Enable C. MAGICIAN')),
    );
  });

  test(
    'SD operation failures preserve the file list and do not report success',
    () async {
      final backend = FakeBackend()
        ..transfer = () => Stream.error(
          const BackendFailure('device_error', 'SD disconnected'),
        );
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..sdPresent = true
        ..showingSd = true
        ..sdEntries = entries;
      addTearDown(c.dispose);
      await c.sdCommand(['--sd-delete', '/example']);
      expect(c.error, contains('SD disconnected'));
      expect(c.finished, false);
      expect(c.sdEntries, entries);
      backend.connected = [];
      await c.refreshDevices();
      expect(c.sdPresent, false);
      expect(c.showingSd, false);
      expect(c.sdEntries, isEmpty);
    },
  );

  testWidgets(
    'SD download confirmation starts transfer with the original file name',
    (tester) async {
      tester.view.physicalSize = const Size(820, 660);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = FileSelectorPlatform.instance;
      addTearDown(() => FileSelectorPlatform.instance = previous);
      final picker = FakeFileSelector();
      FileSelectorPlatform.instance = picker;
      final backend = FakeBackend();
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..sdPresent = true
        ..showingSd = true
        ..sdDirectory = '/CHROMATIC'
        ..sdEntries = [entries.last];
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      await tester.tap(find.byTooltip('Copy to PC'));
      await tester.pump();
      expect(picker.suggestedName, 'ボンバーマン.gbc');
      picker.selection.complete('/tmp/backup.gbc');
      await tester.pumpAndSettle();
      expect(backend.calls.single.take(5), [
        '--sd-get',
        '/CHROMATIC/ボンバーマン.gbc',
        '--file',
        '/tmp/backup.gbc',
        '--force',
      ]);
      expect(c.finished, true);
    },
  );
}
