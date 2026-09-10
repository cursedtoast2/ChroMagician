import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/update_install.dart';
import 'package:chromatic_pc_backup/app_update.dart';

Future<void> main() async {
  final bundle = File(Platform.resolvedExecutable).parent;
  final library = DynamicLibrary.open(p.join(bundle.path, 'locked.dll'));
  final value = library.lookupFunction<Int32 Function(), int Function()>(
    'fixture_value',
  )();
  if (value != 42) exit(20);
  final root = Directory(Platform.environment['CHROMAGIC_TEST_ROOT']!);
  final version = await bundleVersion(bundle);
  final role = Platform.environment['CHROMAGIC_UPDATE_FAILED'] == '1'
      ? 'restored'
      : version == '1.0.0'
      ? 'parent'
      : 'updated';
  await File(p.join(root.path, '$role.json')).writeAsString(
    jsonEncode({'pid': pid, 'identity': await processIdentity(pid)}),
    flush: true,
  );
  final mode = await File(p.join(bundle.path, 'mode')).readAsString();
  if (mode == 'exit') exit(14);
  if (mode != 'hang') await acknowledgeAppUpdate();
  final work = Platform.environment['CHROMAGIC_TEST_HANDOFF'];
  if (role == 'parent' && work != null) {
    while (!await File(p.join(root.path, 'begin')).exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final update = LocalAppUpdate(Directory(work), bundle, '1.0.1');
    final cancel = Platform.environment['CHROMAGIC_TEST_CANCEL'] == '1';
    try {
      await update.restart(() async {
        await File(p.join(root.path, 'released')).writeAsString('USB released');
        if (cancel) throw StateError('Test cancellation before exit');
      });
    } catch (_) {
      if (!cancel) rethrow;
      await update.discard();
      await File(p.join(root.path, 'canceled')).writeAsString('canceled');
    }
  }
  while (true) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}
