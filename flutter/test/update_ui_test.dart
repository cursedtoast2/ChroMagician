import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/app.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'package:chromatic_pc_backup/releases.dart';
import 'package:chromatic_pc_backup/updates.dart';
import 'package:chromatic_pc_backup/app_update.dart';
import 'package:chromatic_pc_backup/app_update_dialog.dart';
import 'controller_test.dart' show FakeBackend;
import 'releases_test.dart' show FakeReleases, releaseJson;

class FakeInstaller implements AppInstaller {
  final result = Completer<PreparedAppUpdate>();
  int calls = 0;
  @override
  Future<PreparedAppUpdate> prepare(
    GitHubRelease release,
    void Function(String) status,
  ) {
    calls++;
    status('Downloading update...');
    return result.future;
  }
}

class FakePrepared extends PreparedAppUpdate {
  bool restarted = false, discarded = false;
  @override
  Future<void> restart(Future<void> Function() beforeExit) async {
    await beforeExit();
    restarted = true;
  }

  @override
  Future<void> discard() async {
    discarded = true;
  }
}

void main() {
  for (final action in ['install', 'cancel', 'failure']) {
    testWidgets('app update $action uses installer without opening a browser', (
      tester,
    ) async {
      final installer = FakeInstaller();
      final prepared = FakePrepared();
      var paused = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AppUpdateDialog(
                  release: GitHubRelease(appRepository, releaseJson('v1.1.0')),
                  installer: installer,
                  ignore: () async {},
                  beforeExit: () async {
                    paused = true;
                  },
                  resume: () async {},
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update'));
      await tester.pump();
      expect(installer.calls, 1);
      expect(find.text('Downloading update...'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      if (action == 'cancel') {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      if (action == 'failure') {
        installer.result.completeError(
          const ReleaseFailure('The download did not pass verification.'),
        );
      } else {
        installer.result.complete(prepared);
      }
      if (action == 'install') {
        await tester.pump();
      } else {
        await tester.pumpAndSettle();
      }
      expect(paused, action == 'install');
      expect(prepared.restarted, action == 'install');
      if (action == 'cancel') expect(prepared.discarded, true);
      if (action == 'failure') {
        expect(
          find.text('The download did not pass verification.'),
          findsOneWidget,
        );
        expect(find.text('Update'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('rollback notice is visible even when release check is offline', (
    tester,
  ) async {
    final c = CartController(FakeBackend());
    final updates = ReleaseUpdates(
      ReleaseClient(Directory('/unused'), transport: FakeReleases()),
      '1.0.0',
    )..restoredPreviousVersion = true;
    addTearDown(c.dispose);
    addTearDown(updates.dispose);
    await tester.pumpWidget(ChromaticApp(controller: c, updates: updates));
    await tester.pumpAndSettle();
    expect(find.text('Could not install update'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Could not install update'), findsNothing);
  });
  testWidgets(
    'update prompt waits for transfer; firmware badge follows connected version',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 980);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = CartController(FakeBackend())
        ..port = '/dev/ttyTEST'
        ..busy = true;
      final updates =
          ReleaseUpdates(
              ReleaseClient(Directory('/unused'), transport: FakeReleases()),
              '1.0.0',
            )
            ..appUpdate = GitHubRelease(appRepository, releaseJson('v1.1.0'))
            ..firmware = GitHubRelease(
              firmwareRepository,
              releaseJson('v1.1.0'),
            );
      addTearDown(c.dispose);
      addTearDown(updates.dispose);
      c.setFirmwareVersion({
        'chromatic': 'ChroMagic 1.0.0 (4.2)',
        'fpga': '18.37',
        'mcu': 'v0.13.4',
      });
      await tester.pumpWidget(ChromaticApp(controller: c, updates: updates));
      await tester.pump();
      expect(find.text('ChroMagician update available'), findsNothing);
      expect(find.byTooltip('ChroMagic update available'), findsOneWidget);
      c.busy = false;
      c.setFirmwareVersion({
        'chromatic': 'ChroMagic 1.0.0 (4.2)',
        'fpga': '18.37',
        'mcu': 'v0.13.4',
      });
      await tester.pumpAndSettle();
      expect(find.text('ChroMagician update available'), findsOneWidget);
      expect(find.text("Don't ask again for this release"), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      c.setFirmwareVersion({
        'chromatic': 'ChroMagic 1.1.0 (4.2)',
        'fpga': '18.37',
        'mcu': 'v0.13.4',
      });
      await tester.pumpAndSettle();
      expect(find.byTooltip('ChroMagic update available'), findsNothing);
      expect(find.text('ChroMagician update available'), findsNothing);
      c.clearFirmwareVersion();
      c.port = null;
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
