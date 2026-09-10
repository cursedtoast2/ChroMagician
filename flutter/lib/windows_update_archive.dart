import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'releases.dart';
import 'update_install.dart';

Future<void> extractWindowsUpdate(
  String archivePath,
  String workPath,
  String version,
) async {
  final input = InputFileStream(archivePath);
  try {
    final directory = ZipDirectory()..read(input);
    final names = <String>{};
    var expanded = 0;
    for (final header in directory.fileHeaders) {
      final name = header.filename;
      final parts = name.split('/');
      if (parts.last.isEmpty) parts.removeLast();
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      expanded += header.uncompressedSize;
      if (parts.isEmpty ||
          parts.first != 'ChroMagician' ||
          parts.any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                RegExp(r'[\x00-\x1f<>:"\\|?*]').hasMatch(part) ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                RegExp(
                  r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)',
                  caseSensitive: false,
                ).hasMatch(part),
          ) ||
          !names.add(parts.join('/').toLowerCase()) ||
          ![0, 0x8000, 0x4000].contains(type) ||
          (type == 0x4000 && !name.endsWith('/')) ||
          header.file?.filename != name ||
          (header.generalPurposeBitFlag & 1) != 0 ||
          ((header.file?.flags ?? 1) & 1) != 0 ||
          ![0, 8].contains(header.compressionMethod) ||
          expanded > 512 * 1024 * 1024) {
        throw const ReleaseFailure(
          'The app archive contains an invalid path or file.',
        );
      }
    }
    for (final header in directory.fileHeaders) {
      final path = p.joinAll([workPath, ...header.filename.split('/')]);
      if (header.filename.endsWith('/')) {
        await Directory(path).create(recursive: true);
        continue;
      }
      await File(path).parent.create(recursive: true);
      final output = _BoundedOutput(path, header.uncompressedSize);
      try {
        ArchiveFile.file(
          header.filename,
          header.uncompressedSize,
          header.file!,
        ).writeContent(output);
        if (output.length != header.uncompressedSize ||
            output.crc != header.crc32) {
          throw const ReleaseFailure('The app archive is damaged.');
        }
      } finally {
        output.closeSync();
      }
    }
  } finally {
    input.closeSync();
  }
  final bundle = Directory(p.join(workPath, 'ChroMagician'));
  if (await bundleVersion(bundle) != version) {
    throw const ReleaseFailure('The app version does not match the release.');
  }
  for (final name in [
    'chromatic_pc_backup.exe',
    'libexec/chromagician-update.exe',
    'libexec/chromatic-backup.exe',
    'flutter_windows.dll',
  ]) {
    await _validatePe(File(p.join(bundle.path, name)));
  }
  await for (final file in bundle.list(recursive: true)) {
    if (file is File && p.extension(file.path).toLowerCase() == '.dll') {
      await _validatePe(file);
    }
  }
  final snapshot = await File(p.join(bundle.path, 'data/app.so')).open();
  try {
    final bytes = await snapshot.read(20);
    if (bytes.length < 20 ||
        bytes[0] != 0x7f ||
        utf8.decode(bytes.sublist(1, 4), allowMalformed: true) != 'ELF' ||
        bytes[4] != 2 ||
        bytes[5] != 1 ||
        bytes[18] != 62 ||
        bytes[19] != 0) {
      throw const ReleaseFailure('The app update is for a different computer.');
    }
  } finally {
    await snapshot.close();
  }
}

Future<void> _validatePe(File file) async {
  final input = await file.open();
  try {
    final dos = await input.read(64);
    if (dos.length != 64 || dos[0] != 0x4d || dos[1] != 0x5a) {
      throw const FormatException('Invalid Windows executable.');
    }
    final offset = ByteData.sublistView(dos).getUint32(60, Endian.little);
    if (offset < 64 || offset > await input.length() - 26) {
      throw const FormatException('Invalid Windows executable.');
    }
    await input.setPosition(offset);
    final pe = await input.read(26);
    final bytes = ByteData.sublistView(pe);
    if (bytes.getUint32(0, Endian.little) != 0x4550 ||
        bytes.getUint16(4, Endian.little) != 0x8664 ||
        bytes.getUint16(24, Endian.little) != 0x20b) {
      throw const ReleaseFailure('The app update is for a different computer.');
    }
  } finally {
    await input.close();
  }
}

class _BoundedOutput extends OutputFileStream {
  _BoundedOutput(String path, this.maximum)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));
  final int maximum;
  int crc = 0;
  @override
  void writeByte(int value) => writeBytes([value]);
  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (this.length + count > maximum) {
      throw const ReleaseFailure('The app archive is too large.');
    }
    crc = getCrc32(length == null ? bytes : bytes.sublist(0, count), crc);
    super.writeBytes(bytes, length: count);
  }
}
