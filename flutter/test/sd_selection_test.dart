import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chromatic_pc_backup/app.dart';
import 'package:chromatic_pc_backup/backend.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/link.dart';

import 'controller_test.dart' show FakeBackend, crystal;

class SdBackend extends FakeBackend {
  final files = <String, List<Map<String, dynamic>>>{
    '/': [
      {'name': 'Games', 'directory': true, 'size': 0},
      {'name': 'a.gb', 'directory': false, 'size': 1048576},
      {'name': 'a.sav', 'directory': false, 'size': 32768},
      {'name': '日本語.gbc', 'directory': false, 'size': 2097152},
    ],
    '/Games': [],
  };
  bool failAfterFirstMove = false;

  @override
  Stream<BackendEvent> run(List<String> arguments) async* {
    calls.add(arguments);
    if (arguments.first == '--sd-list') {
      yield {
        'event': 'sd_list',
        'path': arguments[1],
        'entries': files[arguments[1]]!,
      };
    } else if (failAfterFirstMove) {
      files['/']!.removeWhere((entry) => entry['name'] == 'a.gb');
      throw const BackendFailure('device_error', 'SD card: interrupted move');
    } else {
      yield {'event': 'sd_list', 'path': '/', 'entries': files['/']!};
    }
    yield {'event': 'complete'};
  }
}

Future<CartController> browser(WidgetTester tester, SdBackend backend) async {
  tester.view.physicalSize = const Size(1180, 980);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = CartController(backend)
    ..port = '/dev/ttyTEST'
    ..sdPresent = true
    ..showingSd = true
    ..sdEntries = List.of(backend.files['/']!);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('capture'),
      child: ChromaticApp(controller: c),
    ),
  );
  return c;
}

Future<void> select(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('sd-select-$name')));
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['CHROMAGICIAN_UI_CAPTURES'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    PackageInfo.setMockInitialValues(
      appName: 'ChroMagician',
      packageName: 'org.chromagic.chromagician',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final font = Platform.environment['CHROMAGICIAN_TEST_FONT'];
    if (font != null) {
      final loader = FontLoader('Roboto')
        ..addFont(File(font).readAsBytes().then(ByteData.sublistView));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  testWidgets(
    'About links to the creator and the badge shows physical cart capacity',
    (tester) async {
      final c = await browser(tester, SdBackend());
      c.showingSd = false;
      c.cartridge = {...crystal, 'rom_size': 1048576, 'cart_size': 4194304};
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: ChromaticApp(controller: c),
        ),
      );
      expect(find.text('4 MiB CART'), findsOneWidget);
      expect(find.text('1 MiB ROM'), findsNothing);
      c.cartridge = crystal;
      await tester.pumpWidget(ChromaticApp(controller: c));
      expect(find.text('2 MiB CART'), findsNothing);
      c.port = null;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: ChromaticApp(controller: c),
        ),
      );
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(find.textContaining('CursedToast'), findsOneWidget);
      expect(
        tester.widget<Link>(find.byType(Link)).uri,
        Uri.parse('https://x.com/CursedToastSDA'),
      );
      expect(
        find.textContaining(
          'not affiliated with, endorsed by, or sponsored by ModRetro or Nintendo',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'We do not distribute commercial games or support piracy.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      await capture(tester, 'about');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  for (final decision in ['cancel', 'delete', 'reconnected']) {
    testWidgets(
      'bulk deletion $decision respects the selected files and confirmation',
      (tester) async {
        final backend = SdBackend();
        final c = await browser(tester, backend);
        await select(tester, 'a.gb');
        await select(tester, 'a.sav');
        expect(find.byIcon(Icons.insert_drive_file_outlined), findsNothing);
        expect(find.text('2 selected'), findsOneWidget);
        await capture(tester, 'sd-selection');
        await tester.tap(find.byKey(const ValueKey('sd-delete-selected')));
        await tester.pumpAndSettle();
        expect(find.text('Delete 2 items?'), findsOneWidget);
        expect(backend.calls, isEmpty);
        if (decision == 'reconnected') c.sdGeneration++;
        await tester.tap(
          decision == 'cancel'
              ? find.widgetWithText(TextButton, 'Cancel')
              : find.widgetWithText(FilledButton, 'Delete'),
        );
        await tester.pumpAndSettle();
        if (decision == 'delete') {
          expect(backend.calls.single.take(3), [
            '--sd-delete-many',
            '/a.gb',
            '/a.sav',
          ]);
          expect(c.finished, true);
          expect(find.text('2 selected'), findsNothing);
        } else {
          expect(backend.calls, isEmpty);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final fail in [false, true]) {
    testWidgets(
      'bulk move ${fail ? 'refreshes after partial failure' : 'uses the SD folder picker'}',
      (tester) async {
        final backend = SdBackend()..failAfterFirstMove = fail;
        final c = await browser(tester, backend);
        await select(tester, 'a.gb');
        await select(tester, 'a.sav');
        await tester.tap(find.byKey(const ValueKey('sd-move-selected')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Move here'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Games'),
          ),
        );
        await tester.pumpAndSettle();
        expect(c.sdDirectory, '/');
        await capture(tester, 'sd-move');
        await tester.tap(find.text('Move here'));
        await tester.pumpAndSettle();
        final mutation = backend.calls
            .where((args) => args.first == '--sd-move')
            .single;
        expect(mutation.take(5), [
          '--sd-move',
          '/a.gb',
          '/a.sav',
          '--destination',
          '/Games',
        ]);
        expect(c.finished, !fail);
        if (fail) {
          expect(c.error, contains('interrupted move'));
          expect(find.text('a.gb'), findsNothing);
          expect(find.text('1 selected'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('select-all supports folders and navigation clears selection', (
    tester,
  ) async {
    final backend = SdBackend();
    final c = await browser(tester, backend);
    await tester.tap(find.byKey(const ValueKey('sd-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('4 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sd-delete-selected')));
    await tester.pumpAndSettle();
    expect(
      find.text('This includes everything inside the selected folders.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Games'));
    await tester.pumpAndSettle();
    expect(c.sdDirectory, '/Games');
    expect(find.text('4 selected'), findsNothing);
    expect(find.byKey(const ValueKey('sd-move-selected')), findsNothing);
  });
}
