import 'dart:convert';
import 'dart:io';
import 'package:chromatic_pc_backup/app_update.dart';
import 'package:chromatic_pc_backup/releases.dart';

Future<void> main(List<String> args) async {
  final release = GitHubRelease(
    appRepository,
    jsonDecode(await File(args[1]).readAsString()) as Map<String, dynamic>,
  );
  final updater = AppUpdater(
    ReleaseClient(Directory(args[2])),
    installation: Directory(args[0]),
  );
  final prepared = await updater.prepare(release, stdout.writeln);
  await prepared.restart(() async {});
}
