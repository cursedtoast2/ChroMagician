import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/app.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'package:chromatic_pc_backup/firmware.dart';
import 'package:chromatic_pc_backup/firmware_dialog.dart';

import 'auto_read_test.dart' show WatchingBackend;
import 'controller_test.dart' show FakeBackend, crystal;
import 'firmware_test.dart' show FirmwareBackend;

FirmwareBundle dialogBundle() => FirmwareBundle(Directory('/unused'), {}, [
  for (final id in ['chromagician', 'stock'])
    FirmwareRelease({
      'id': id,
      'label': id == 'stock' ? 'Stock 4.2' : 'ChroMagic 1.0.0-rc.1 (4.2)',
      'version': {
        'mcu': 'v0.13.4',
        'fpga': id == 'stock' ? '18.8' : '18.10',
        'chromatic': id == 'stock' ? 'v4.2' : 'ChroMagic 1.0.0-rc.1 (4.2)',
      },
      'mcu': <String, String>{},
      'fpga': <String, String>{},
    }),
]);

class ControlledInstaller extends FirmwareInstaller {
  ControlledInstaller(super.backend);
  final pending = Completer<void>();
  final selections = <String>[];
  @override
  Future<void> install(
    FirmwareBundle bundle,
    FirmwareRelease release,
    void Function(FirmwareProgress) report, {
    Directory? logDirectory,
  }) async {
    selections.add(release.id);
    report(const FirmwareProgress('Writing...', component: 'MCU'));
    await pending.future;
    report(const FirmwareProgress('Installed and verified', fraction: 1));
  }
}

class DialogBackend extends FirmwareBackend {
  int deviceReads = 0;

  @override
  Future<List<String>> devices() {
    deviceReads++;
    return super.devices();
  }
}

void main() {
  for (final knownVersion in [true, false]) {
    testWidgets(
      'popup opens without probing USB when firmware version is ${knownVersion ? 'known' : 'unknown'}',
      (tester) async {
        final backend = DialogBackend();
        final c = CartController(backend)..port = 'COM4';
        if (knownVersion) c.setFirmwareVersion(backend.version);
        addTearDown(c.dispose);
        await c.beginFirmware();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            home: FirmwareDialog(
              controller: c,
              loadBundle: () async => dialogBundle(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Checking...'), findsNothing);
        expect(backend.deviceReads, 0);
        expect(backend.queries, isEmpty);
        expect(
          find.text(
            'Installed: ChroMagic 1.0.0-rc.1 (4.2) · MCU v0.13.4 · FPGA 18.12',
          ),
          knownVersion ? findsOneWidget : findsNothing,
        );
        final install = find.widgetWithText(FilledButton, 'Install ChroMagic');
        expect(tester.widget<FilledButton>(install).onPressed, isNotNull);

        backend.ports = [];
        await c.refreshDevices();
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(install).onPressed, isNull);
        expect(find.textContaining('Installed:'), findsNothing);

        backend.ports = ['COM9'];
        await c.refreshDevices();
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(install).onPressed, isNotNull);
        expect(find.textContaining('Installed:'), findsNothing);
        expect(backend.queries, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'firmware owns USB while normal discovery is still waiting for a cart',
    () async {
      final backend = WatchingBackend();
      final c = CartController(backend);
      addTearDown(() async {
        await c.stopDiscovery();
        c.dispose();
      });
      final discovery = c.startDiscovery();
      await Future<void>.delayed(Duration.zero);
      expect(c.inspecting, true);
      expect(await c.beginFirmware(), true);
      await discovery;
      expect(backend.trace, ['watch', 'stop']);
      expect(c.busy, false);
      backend.connected = [];
      c.setFirmwareBusy(true);
      await c.refreshDevices();
      expect(
        c.port,
        '/dev/ttyTEST',
      );
      c.setFirmwareBusy(false);
      c.cartridge = crystal;
      c.chooseFile('/tmp/no-transfer.gb');
      await c.transfer();
      expect(backend.calls, isEmpty);
      backend.connected = ['/dev/ttyNEW'];
      final ended = c.endFirmware();
      await Future<void>.delayed(Duration.zero);
      backend.monitor!.add({'event': 'cartridge_unavailable'});
      await ended;
      expect(c.port, '/dev/ttyNEW');
      expect(backend.trace, ['watch', 'stop', 'watch']);
    },
  );

  test('real cartridge transfers prevent firmware acquiring USB', () async {
    final c = CartController(FakeBackend())
      ..port = '/dev/ttyTEST'
      ..busy = true;
    addTearDown(c.dispose);
    expect(await c.beginFirmware(), false);
    expect(c.firmwareOpen, false);
  });

  testWidgets(
    'firmware requires USB but does not require a game or C. MAGICIAN mode',
    (tester) async {
      tester.view.physicalSize = const Size(820, 660);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend()
        ..inspection = () => Stream.fromIterable([
          {
            'event': 'device_status',
            'enabled': false,
            'cartridge_present': null,
          },
          {'event': 'cartridge_unavailable'},
        ]);
      final c = CartController(backend);
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      final button = find.widgetWithText(OutlinedButton, 'Firmware');
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      expect(await c.beginFirmware(), false);
      await c.refreshDevices();
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
      expect(find.text('Back up game'), findsNothing);
      backend.connected = [];
      await c.refreshDevices();
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'popup needs an explicit install click and cannot close mid-flash',
    (tester) async {
      final backend = FirmwareBackend();
      final c = CartController(backend)..port = 'COM4';
      addTearDown(c.dispose);
      await c.beginFirmware();
      final installer = ControlledInstaller(backend);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => FirmwareDialog(
                    controller: c,
                    loadBundle: () async => dialogBundle(),
                    installer: installer,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(installer.selections, isEmpty);
      expect(find.text('No Warranty'), findsOneWidget);
      expect(
        find.text('Keep Chromatic powered on and connected to USB'),
        findsOneWidget,
      );
      await tester.tap(find.text('ChroMagic 1.0.0-rc.1 (4.2)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stock 4.2').last);
      await tester.pumpAndSettle();
      backend.ports = [];
      await c.refreshDevices();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Restore stock'),
            )
            .onPressed,
        isNull,
      );
      expect(installer.selections, isEmpty);
      backend.ports = ['COM4'];
      await c.refreshDevices();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Restore stock'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Restore stock'));
      await tester.pump();
      expect(installer.selections, ['stock']);
      expect(c.busy, true);
      expect(find.text('No Warranty'), findsNothing);
      expect(find.textContaining('provided "as is"'), findsNothing);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
            .onPressed,
        isNull,
      );
      final context = tester.element(find.byType(FirmwareDialog));
      await Navigator.of(context).maybePop();
      await tester.pump();
      expect(find.byType(FirmwareDialog), findsOneWidget);
      installer.verifiedPort = 'COM9';
      backend.ports = ['COM9'];
      installer.pending.complete();
      await tester.pumpAndSettle();
      expect(c.busy, false);
      expect(c.requiresFirmwareInstall, true);
      expect(c.port, 'COM9');
      await c.refreshDevices();
      expect(c.requiresFirmwareInstall, true);
      expect(find.text('Stock 4.2 installed and verified.'), findsOneWidget);
      expect(find.text('No Warranty'), findsNothing);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(FirmwareDialog), findsNothing);
      await c.endFirmware();
      expect(tester.takeException(), null);
    },
  );
}
