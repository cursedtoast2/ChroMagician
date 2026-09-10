import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:chromatic_pc_backup/app_update.dart';
import 'package:chromatic_pc_backup/update_install.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('Usage: bundle-directory output-directory');
  }
  final bundle = Directory(args[0]).absolute;
  final output = await Directory(args[1]).absolute.create(recursive: true);
  final version = await bundleVersion(bundle);
  final zip = File(
    p.join(output.path, 'ChroMagician-$version-windows-x64.zip'),
  );
  final encoder = ZipFileEncoder()..create(zip.path);
  try {
    await for (final file in bundle.list(recursive: true, followLinks: false)) {
      if (file is Link) {
        throw const FormatException('Bundle cannot contain links.');
      }
      if (file is! File) continue;
      await encoder.addFile(
        file,
        'ChroMagician/${p.split(p.relative(file.path, from: bundle.path)).join('/')}',
      );
    }
  } finally {
    await encoder.close();
  }
  final validation = await output.createTemp('.validate-');
  try {
    await extractAppUpdate(zip.path, validation.path, version, 'windows-x64');
  } finally {
    await validation.delete(recursive: true);
  }
  final digest = await sha256.bind(zip.openRead()).first;
  await File(
    '${zip.path}.sha256',
  ).writeAsString('$digest  ${p.basename(zip.path)}\n');
  stdout.writeln('Validated Windows package: ${zip.path}');
}
