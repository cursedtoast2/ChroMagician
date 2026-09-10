import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/app.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'auto_read_test.dart' show WatchingBackend;
import 'controller_test.dart' show crystal;

void main() {
  testWidgets('mode and readable game control prompts without restarting', (
    tester,
  ) async {
    final backend = WatchingBackend();
    final c = CartController(backend);

    final started = c.startDiscovery();
    await tester.pumpWidget(ChromaticApp(controller: c));
    await tester.pump();
    backend.monitor!.add({
      'event': 'device_status',
      'enabled': false,
      'cartridge_present': null,
    });
    backend.monitor!.add({'event': 'cartridge_unavailable'});
    await tester.pump();
    await started;
    await tester.pumpAndSettle();
    expect(find.text('Enable C. MAGICIAN'), findsOneWidget);
    expect(find.text('Insert a game cartridge'), findsNothing);
    expect(find.text('Back up game'), findsNothing);
    final detail = tester.widget<Text>(
      find.text('Open System settings on your Chromatic.'),
    );
    expect(detail.style!.fontSize, 13);
    expect(detail.style!.color!.a, lessThan(1));

    backend.monitor!.add({
      'event': 'device_status',
      'enabled': true,
      'cartridge_present': false,
    });
    await tester.pumpAndSettle();
    expect(find.text('Insert a game cartridge'), findsOneWidget);
    expect(find.text('Enable C. MAGICIAN'), findsNothing);
    for (final present in [true, null]) {
      backend.monitor!.add({
        'event': 'device_status',
        'enabled': true,
        'cartridge_present': present,
      });
      await tester.pumpAndSettle();
      expect(find.text('Insert a game cartridge'), findsOneWidget);
      expect(find.text('Could not read the cartridge'), findsNothing);
      expect(find.text('Back up game'), findsNothing);
    }
    backend.monitor!.add({
      'event': 'cartridge_inspected',
      'cartridge': crystal,
    });
    await tester.pumpAndSettle();
    expect(find.text('PM_CRYSTAL'), findsOneWidget);

    backend.monitor!.add({'event': 'cartridge_unavailable'});
    await tester.pumpAndSettle();
    expect(find.text('Insert a game cartridge'), findsOneWidget);
    expect(find.text('Could not read the cartridge'), findsNothing);
    expect(find.text('Back up game'), findsNothing);
    backend.monitor!.add({
      'event': 'cartridge_inspected',
      'cartridge': crystal,
    });
    await tester.pumpAndSettle();
    expect(find.text('PM_CRYSTAL'), findsOneWidget);
    expect(find.text('Insert a game cartridge'), findsNothing);

    backend.monitor!.add({
      'event': 'sd_status',
      'present': false,
      'error': null,
    });
    await tester.pumpAndSettle();
    expect(find.text('SD Card'), findsNothing);
    expect(find.byTooltip('No SD card installed'), findsOneWidget);
    final sdButton = find.byKey(const ValueKey('cart-sd-action'));
    expect(tester.widget<FilledButton>(sdButton).onPressed, isNull);

    backend.monitor!.add({
      'event': 'sd_status',
      'present': false,
      'error': 'ESP_ERR_TIMEOUT',
    });
    await tester.pumpAndSettle();
    expect(c.sdPresent, false);
    expect(c.sdError, 'ESP_ERR_TIMEOUT');
    await tester.tap(find.text('SD Card'));
    await tester.pumpAndSettle();
    expect(find.text('The SD card is not responding'), findsOneWidget);
    expect(find.textContaining('ESP_ERR_'), findsNothing);
    expect(backend.calls, isEmpty);

    backend.monitor!.add({
      'event': 'sd_status',
      'present': true,
      'error': null,
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cartridge'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(sdButton).onPressed, isNotNull);
    expect(find.byTooltip('No SD card installed'), findsNothing);

    backend.monitor!.add({
      'event': 'device_status',
      'enabled': false,
      'cartridge_present': null,
    });
    backend.monitor!.add({'event': 'cartridge_unavailable'});
    await tester.pumpAndSettle();
    expect(find.text('Enable C. MAGICIAN'), findsOneWidget);
    expect(find.text('Insert a game cartridge'), findsNothing);
    expect(find.text('SD Card'), findsNothing);
    expect(find.text('Back up game'), findsNothing);
    expect(backend.trace, ['watch']);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    await tester.pump();
  });
}
