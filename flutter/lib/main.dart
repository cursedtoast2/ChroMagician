import 'dart:async';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'backend.dart';
import 'controller.dart';
import 'catalog.dart';
import 'updates.dart';
import 'update_install.dart';

const defaultWindowSize = Size(1180, 980);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: defaultWindowSize,
      minimumSize: Size(820, 660),
      title: 'ChroMagician',
      backgroundColor: ink,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  try {
    GameCatalog? catalog;
    try {
      catalog = await GameCatalog.configured();
    } on Object {
    }
    final controller = CartController(
      ProcessBackend(ProcessBackend.resolveExecutable()),
      catalog: catalog,
    );
    ReleaseUpdates? updates;
    try {
      updates = await ReleaseUpdates.configured();
    } on Object {
    }
    runApp(ChromaticApp(controller: controller, updates: updates));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(acknowledgeAppUpdate());
    });
    if (updates != null) unawaited(updates.check());
    unawaited(controller.startDiscovery());
  } on Object catch (error) {
    runApp(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: SelectableText(error.toString()),
            ),
          ),
        ),
      ),
    );
  }
}
