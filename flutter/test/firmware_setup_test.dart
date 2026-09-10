import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/app.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'auto_read_test.dart' show WatchingBackend;
import 'controller_test.dart' show FakeBackend, crystal;

const stock = {'chromatic': 'v4.2', 'mcu': 'v0.13.4', 'fpga': '18.8'};
const custom = {
  'chromatic': 'ChroMagic 1.0.0-rc.1 (4.2)',
  'mcu': 'v0.13.4',
  'fpga': '18.12',
};

void main() {
  test(
    'known ChroMagic keeps discovery active after an unanswered mode query',
    () async {
      final backend = WatchingBackend()..firmware = custom;
      final c = CartController(backend);
      addTearDown(c.dispose);
      final started = c.startDiscovery();
      await Future<void>.delayed(Duration.zero);
      expect(c.inspecting, true);
      expect(c.pcModeEnabled, isNull);
      expect(c.needsPcMode, true);
      expect(c.loadingGame, false);
      backend.monitor!.add({'event': 'device_status', 'enabled': null});
      await started;
      expect(c.inspecting, false);
      expect(c.needsPcMode, true);
      expect(backend.monitor, isNotNull);
      backend.monitor!.add({'event': 'device_status', 'enabled': true});
      backend.monitor!.add({
        'event': 'cartridge_inspected',
        'cartridge': crystal,
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.cartridgeReady, true);
      expect(c.title, 'PM_CRYSTAL');
      expect(c.needsPcMode, false);
      expect(backend.trace, ['watch']);
      await c.stopDiscovery();
    },
  );

  testWidgets(
    'known ChroMagic shows mode instructions while status is pending',
    (tester) async {
      final c = CartController(FakeBackend())
        ..port = 'COM4'
        ..setFirmwareVersion(custom)
        ..busy = true
        ..inspecting = true;
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.text('Enable C. MAGICIAN'), findsOneWidget);
      expect(
        find.text('Open System settings on your Chromatic.'),
        findsOneWidget,
      );
      expect(find.text('Loading'), findsNothing);
      expect(find.text('Open the Chromatic menu'), findsNothing);
      c.notifyListeners();
      await tester.pump();
      expect(find.text('Enable C. MAGICIAN'), findsOneWidget);
      expect(find.text('Open the Chromatic menu'), findsNothing);
    },
  );

  test(
    'silent discovery offers installation and identifies stock after reconnect',
    () async {
      final backend = WatchingBackend()..firmware = null;
      final c = CartController(backend);
      addTearDown(c.dispose);
      final started = c.startDiscovery();
      await Future<void>.delayed(Duration.zero);
      backend.monitor!.add({'event': 'device_status', 'enabled': null});
      backend.monitor!.add({'event': 'cartridge_unavailable'});
      await Future<void>.delayed(Duration.zero);
      await started;
      expect(c.showFirmwareSetup, true);
      expect(c.pcModeEnabled, isNull);

      backend.connected = [];
      await c.refreshDevices();
      backend.firmware = stock;
      backend.connected = ['COM4'];
      await c.refreshDevices();
      expect(backend.firmwareReads, 2);
      expect(backend.monitor, isNull);
      expect(c.requiresFirmwareInstall, true);
      await c.stopDiscovery();
    },
  );

  test(
    'known off mode survives an unanswered poll after closing Firmware',
    () async {
      final backend = WatchingBackend();
      final c = CartController(backend);
      addTearDown(c.dispose);
      final started = c.startDiscovery();
      await Future<void>.delayed(Duration.zero);
      backend.monitor!.add({'event': 'device_status', 'enabled': false});
      backend.monitor!.add({'event': 'cartridge_unavailable'});
      await Future<void>.delayed(Duration.zero);
      await started;
      await c.beginFirmware();
      final resumed = c.endFirmware();
      await Future<void>.delayed(Duration.zero);
      backend.monitor!.add({'event': 'device_status', 'enabled': null});
      backend.monitor!.add({'event': 'cartridge_unavailable'});
      await Future<void>.delayed(Duration.zero);
      await resumed;
      expect(c.pcModeEnabled, false);
      expect(backend.firmwareReads, 1);

      backend.monitor!.add({'event': 'device_status', 'enabled': true});
      backend.monitor!.add({'event': 'cartridge_unavailable'});
      await Future<void>.delayed(Duration.zero);
      expect(c.pcModeEnabled, true);
      backend.connected = [];
      await c.refreshDevices();
      expect(c.pcModeEnabled, isNull);
      expect(c.port, isNull);
      await c.stopDiscovery();
    },
  );

  test(
    'failed wake-time identification cannot repeatedly restart discovery',
    () async {
      final backend = WatchingBackend()
        ..firmwareQuery = () async => throw Exception('no reply');
      final c = CartController(backend);
      addTearDown(c.dispose);
      final started = c.startDiscovery();
      await Future<void>.delayed(Duration.zero);
      backend.monitor!.add({'event': 'device_status', 'enabled': null});
      backend.monitor!.add({'event': 'cartridge_unavailable'});
      await Future<void>.delayed(Duration.zero);
      await started;
      backend.monitor!.add({'event': 'device_status', 'enabled': false});
      await Future<void>.delayed(Duration.zero);
      expect(backend.firmwareReads, 2);
      final watch = backend.monitor;
      for (var i = 0; i < 3; i++) {
        watch!.add({'event': 'device_status', 'enabled': false});
        watch.add({'event': 'cartridge_unavailable'});
        await Future<void>.delayed(Duration.zero);
        await c.refreshDevices();
      }
      expect(backend.monitor, same(watch));
      expect(backend.firmwareReads, 2);
      expect(c.pcModeEnabled, false);
      await c.stopDiscovery();
    },
  );

  testWidgets(
    'unknown connected console offers installation without mode instructions',
    (tester) async {
      final c = CartController(FakeBackend())..port = 'COM4';
      addTearDown(c.dispose);
      await tester.pumpWidget(ChromaticApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.text('Open the Chromatic menu'), findsNothing);
      expect(find.text('Install ChroMagic'), findsOneWidget);
      expect(find.text('Connecting to Chromatic'), findsNothing);
      expect(find.text('Insert a game cartridge'), findsNothing);
      expect(find.text('Enable C. MAGICIAN'), findsNothing);
    },
  );

  test('numbered ChroMagic release is recognized without a cartridge', () {
    final c = CartController(FakeBackend());
    addTearDown(c.dispose);
    c.setFirmwareVersion({
      'chromatic': '1.0.0-rc.1 (4.2)',
      'mcu': 'v0.13.4',
      'fpga': '18.37',
    });
    expect(c.hasChroMagic, true);
    expect(c.requiresFirmwareInstall, false);
    c.setFirmwareVersion(stock);
    expect(c.hasChroMagic, false);
  });

  for (final awake in [false, true]) {
    testWidgets('stock connected after app startup, console awake=$awake', (
      tester,
    ) async {
      final backend = WatchingBackend()
        ..connected = []
        ..firmware = awake ? stock : null;
      final c = CartController(backend);
      await c.refreshDevices();
      await tester.pumpWidget(ChromaticApp(controller: c));
      expect(find.text('Connect your Chromatic'), findsWidgets);

      backend.connected = ['COM4'];
      await tester.runAsync(() async {
        final connected = c.refreshDevices();
        await Future<void>.delayed(Duration.zero);
        if (!awake) {
          backend.monitor!.add({'event': 'device_status', 'enabled': null});
          backend.monitor!.add({'event': 'cartridge_unavailable'});
        }
        await connected;
      });
      await tester.pumpAndSettle();
      expect(find.text('ChroMagic firmware required'), findsOneWidget);
      expect(find.text('Install ChroMagic'), findsOneWidget);
      expect(find.text('Open the Chromatic menu'), findsNothing);
      expect(find.text('Enable C. MAGICIAN'), findsNothing);
      expect(find.text('Loading'), findsNothing);
      expect(c.hasChroMagic, false);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Install ChroMagic'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.runAsync(() async {
        expect(await c.beginFirmware(), true);
        expect(backend.monitor, isNull);
        await c.stopDiscovery();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }

  testWidgets('disconnect is noticed while the initial version query waits', (
    tester,
  ) async {
    final pending = Completer<Map<String, String>?>();
    final backend = FakeBackend()..firmwareQuery = () => pending.future;
    final c = CartController(backend);
    addTearDown(c.dispose);
    final started = c.startDiscovery();
    await tester.pump();
    expect(c.inspecting, true);
    backend.connected = [];
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.port, isNull);
    expect(c.busy, false);

    backend.connected = ['/dev/ttyTEST'];
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.firmwareReads, 1);
    pending.complete(stock);
    await tester.pump();
    await started;
    expect(c.firmwareVersion, isNull);
    backend.firmwareQuery = null;
    backend.firmware = custom;
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.firmwareReads, 2);
    expect(c.cartridgeReady, true);
    expect(c.requiresFirmwareInstall, false);
    await c.stopDiscovery();
  });

  testWidgets('disconnect is noticed before the first cartridge sample', (
    tester,
  ) async {
    final backend = WatchingBackend();
    final c = CartController(backend);
    addTearDown(c.dispose);
    final started = c.startDiscovery();
    await tester.pump();
    expect(backend.monitor, isNotNull);
    expect(c.inspecting, true);
    backend.connected = [];
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.port, isNull);
    expect(c.busy, false);
    expect(backend.trace, ['watch', 'stop']);
    await started;
    await c.stopDiscovery();
  });

  testWidgets(
    'stock firmware shows installation instead of cartridge or custom-mode instructions',
    (tester) async {
      final backend = FakeBackend()..firmware = stock;
      final c = CartController(backend);
      addTearDown(c.dispose);
      await c.startDiscovery();
      await tester.pumpWidget(ChromaticApp(controller: c));
      await tester.pumpAndSettle();
      expect(c.requiresFirmwareInstall, true);
      expect(c.cartridgeReady, false);
      expect(find.text('ChroMagic firmware required'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Install ChroMagic'),
            )
            .onPressed,
        isNotNull,
      );
      expect(find.text('Insert a game cartridge'), findsNothing);
      expect(find.textContaining('C. MAGICIAN'), findsNothing);
      expect(find.text('Back up game'), findsNothing);
      expect(backend.calls, isEmpty);
      await c.refreshDevices();
      expect(backend.firmwareReads, 1);
      expect(backend.calls, isEmpty);
      expect(tester.takeException(), null);
      await c.stopDiscovery();
    },
  );

  test(
    'disconnect clears stock state and reads firmware on the next connection',
    () async {
      final backend = FakeBackend()..firmware = stock;
      final c = CartController(backend);
      addTearDown(c.dispose);
      await c.refreshDevices();
      expect(c.requiresFirmwareInstall, true);
      backend.connected = [];
      await c.refreshDevices();
      expect(c.firmwareVersion, null);
      expect(c.requiresFirmwareInstall, false);
      backend.connected = ['/dev/ttyNEW'];
      backend.firmware = custom;
      await c.refreshDevices();
      expect(c.hasChroMagic, true);
      expect(c.requiresFirmwareInstall, false);
      expect(c.cartridgeReady, true);
      expect(backend.firmwareReads, 2);
    },
  );

  test(
    'stock restoration removes old cartridge and SD state immediately',
    () async {
      final c = CartController(FakeBackend())
        ..port = '/dev/ttyTEST'
        ..cartridge = crystal
        ..sdPresent = true
        ..showingSd = true;
      addTearDown(c.dispose);
      c.setFirmwareVersion(stock);
      expect(c.requiresFirmwareInstall, true);
      expect(c.cartridgeReady, false);
      expect(c.sdPresent, false);
      expect(c.showingSd, false);
      c.setFirmwareVersion(custom);
      expect(c.requiresFirmwareInstall, false);
      expect(c.hasChroMagic, true);
    },
  );

  test(
    'a failed firmware query does not disable working cartridge discovery',
    () async {
      final backend = FakeBackend()
        ..firmwareQuery = () async => throw Exception('no reply');
      final c = CartController(backend);
      addTearDown(c.dispose);
      await c.refreshDevices();
      expect(c.requiresFirmwareInstall, false);
      expect(c.cartridgeReady, true);
    },
  );

  test('firmware popup waits for initial query to release USB', () async {
    final pending = Completer<Map<String, String>?>();
    final backend = WatchingBackend()..firmwareQuery = () => pending.future;
    final c = CartController(backend);
    addTearDown(c.dispose);
    final discovery = c.startDiscovery();
    await Future<void>.delayed(Duration.zero);
    expect(c.inspecting, true);
    expect(backend.trace, isEmpty);
    var acquired = false;
    final opening = c.beginFirmware().then((value) => acquired = value);
    await Future<void>.delayed(Duration.zero);
    expect(acquired, false);
    pending.complete(custom);
    await opening;
    await discovery;
    expect(acquired, true);
    expect(c.firmwareOpen, true);
    expect(c.busy, false);
    expect(backend.trace, isEmpty);
    await c.stopDiscovery();
    await c.endFirmware();
  });
}
