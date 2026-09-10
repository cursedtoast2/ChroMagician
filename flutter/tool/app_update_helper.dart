import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/update_install.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) exit(2);
  final plan = File(arguments.single);
  try {
    await installUpdate(plan);
  } on Object {
    if (await plan.parent.exists()) {
      await File(p.join(plan.parent.path, 'error')).writeAsString(
        'The update could not be installed. Please try again.',
        flush: true,
      );
    }
    exitCode = 1;
  }
}
