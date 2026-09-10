import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:chromatic_pc_backup/app_update.dart';
import 'package:chromatic_pc_backup/releases.dart';

class LocalArchive extends ReleaseTransport {
  LocalArchive(this.file);
  final File file;
  @override
  Future<List<int>> get(Uri uri, {bool binary = false, int limit = 0}) =>
      file.readAsBytes();
}

Future<void> main(List<String> args) async {
  final file = File(args[1]).absolute;
  final version = args[2];
  final platform = Platform.isWindows
      ? 'windows-x64.zip'
      : args.length > 4
      ? 'linux-x64.${args[4]}'
      : 'linux-x64.tar.gz';
  final client = ReleaseClient(
    Directory(args[3]),
    transport: LocalArchive(file),
  );
  final release = GitHubRelease(appRepository, {
    'tag_name': 'v$version',
    'assets': [
      {
        'name': 'ChroMagician-$version-$platform',
        'id': 1,
        'size': await file.length(),
        'digest': 'sha256:${await sha256.bind(file.openRead()).first}',
      },
    ],
  });
  final updater = AppUpdater(client, installation: Directory(args[0]));
  final prepared = await updater.prepare(release, stdout.writeln);
  try {
    await prepared.restart(() async {});
  } finally {
    await prepared.discard();
  }
}
