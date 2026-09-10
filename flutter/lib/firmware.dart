import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'backend.dart';

class FirmwareFailure implements Exception {
  const FirmwareFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class FirmwareRelease {
  FirmwareRelease(Map<String, dynamic> value)
    : id = value['id'] as String,
      label = value['label'] as String,
      version = Map<String, String>.from(value['version'] as Map),
      mcu = Map<String, String>.from(value['mcu'] as Map),
      fpga = Map<String, String>.from(value['fpga'] as Map);
  final String id;
  final String label;
  final Map<String, String> version, mcu, fpga;
}

class FirmwareBundle {
  FirmwareBundle(this.directory, this.tools, this.releases);
  final Directory directory;
  final Map<String, List<String>> tools;
  final List<FirmwareRelease> releases;

  static Future<FirmwareBundle> load({String? directory}) async {
    final root = Directory(
      directory ??
          Platform.environment['CHROMATIC_FIRMWARE_DIR'] ??
          p.join(p.dirname(Platform.resolvedExecutable), 'firmware'),
    );
    final file = File(p.join(root.path, 'manifest.json'));
    if (!await file.exists()) {
      throw const FirmwareFailure('Firmware is unavailable in this build.');
    }
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (value['schema_version'] != 1) {
      throw const FirmwareFailure('This firmware bundle needs updating.');
    }
    final tools = (value['tools'] as Map).map(
      (key, command) =>
          MapEntry(key as String, List<String>.from(command as List)),
    );
    for (final name in ['esptool', 'openFPGALoader']) {
      if (tools[name]?.isNotEmpty != true) {
        throw FirmwareFailure('$name is missing from this firmware bundle.');
      }
    }
    final releases = (value['releases'] as List)
        .map((value) => FirmwareRelease(value as Map<String, dynamic>))
        .toList();
    if (releases.length != 2 ||
        !releases.map((release) => release.id).toSet().containsAll([
          'chromagician',
          'stock',
        ])) {
      throw const FirmwareFailure(
        'Both ChroMagic and stock firmware are required.',
      );
    }
    return FirmwareBundle(root, tools, releases);
  }

  Future<File> stage(
    Map<String, String> artifact,
    Directory staging,
    String name,
  ) async {
    final relative = artifact['file'];
    final hash = artifact['sha256'];
    if (relative == null ||
        p.isAbsolute(relative) ||
        !p.isWithin(
          directory.absolute.path,
          p.join(directory.absolute.path, relative),
        ) ||
        hash == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FirmwareFailure('Invalid local firmware manifest.');
    }
    final source = File(p.join(directory.path, relative));
    if (!await source.exists()) {
      throw FirmwareFailure('Missing firmware file: $relative');
    }
    final file = await source.copy(p.join(staging.path, name));
    if ((await sha256.bind(file.openRead()).first).toString() != hash) {
      throw FirmwareFailure('Firmware checksum does not match: $relative');
    }
    var length = await file.length();
    if (name == 'mcu.bin') {
      final offset = int.tryParse(artifact['offset'] ?? '0');
      if (offset == null ||
          ![0, 0x10000].contains(offset) ||
          length - offset < 256 ||
          length - offset > 0x100000) {
        throw const FirmwareFailure(
          'The MCU application has an invalid size or offset.',
        );
      }
      if (offset != 0) {
        final application = (await file.readAsBytes()).sublist(offset);
        await file.writeAsBytes(application, flush: true);
        length = application.length;
      }
      final handle = await file.open();
      try {
        if (length < 256 ||
            length > 0x100000 ||
            (await handle.read(1)).first != 0xe9) {
          throw const FirmwareFailure(
            'The MCU file is not a Chromatic application image.',
          );
        }
      } finally {
        await handle.close();
      }
    } else if (length == 0 || length > 16 * 1024 * 1024) {
      throw const FirmwareFailure('The FPGA image has an invalid size.');
    }
    return file;
  }
}

class FirmwareProgress {
  const FirmwareProgress(this.phase, {this.component, this.fraction});
  final String phase;
  final String? component;
  final double? fraction;
}

class ToolResult {
  const ToolResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

abstract class FirmwareTools {
  Future<ToolResult> run(
    List<String> command,
    void Function(String) onLine, {
    Duration? timeout,
  });
}

class ProcessFirmwareTools implements FirmwareTools {
  @override
  Future<ToolResult> run(
    List<String> command,
    void Function(String) onLine, {
    Duration? timeout,
  }) async {
    final process = await Process.start(command.first, command.sublist(1));
    var output = '';
    Future<void> drain(Stream<List<int>> stream) async {
      var pending = '';
      await for (final chunk in stream.transform(
        const Utf8Decoder(allowMalformed: true),
      )) {
        pending += chunk;
        final lines = pending.split(RegExp(r'[\r\n]'));
        pending = lines.removeLast();
        if (pending.length > 16384) {
          lines.add(pending);
          pending = '';
        }
        for (final line in lines.where((line) => line.isNotEmpty)) {
          output += '$line\n';
          if (output.length > 65536) {
            output = output.substring(output.length - 65536);
          }
          onLine(line);
        }
      }
      if (pending.isNotEmpty) {
        output += pending;
        onLine(pending);
      }
    }

    final drained = Future.wait([drain(process.stdout), drain(process.stderr)]);
    var timedOut = false;
    final timer = timeout == null
        ? null
        : Timer(timeout, () {
            timedOut = true;
            process
                .kill();
          });
    try {
      final code = await process.exitCode;
      await drained;
      if (timedOut) {
        throw const FirmwareFailure(
          'Firmware tool did not respond during preflight.',
        );
      }
      return ToolResult(code, output);
    } finally {
      timer?.cancel();
    }
  }
}

class FirmwareInstaller {
  FirmwareInstaller(
    this.backend, {
    FirmwareTools? tools,
    this.reconnectDelay = const Duration(seconds: 2),
    this.reconnectAttempts = 15,
  }) : tools = tools ?? ProcessFirmwareTools();
  final CartBackend backend;
  final FirmwareTools tools;
  final Duration reconnectDelay;
  final int reconnectAttempts;
  String? logPath;
  String? verifiedPort;

  Future<Map<String, String>> readVersion(
    String port, {
    bool afterFlash = false,
    Map<String, String>? expectedVersion,
  }) async {
    final version = await backend.firmwareInfo(
      port,
      afterFlash: afterFlash,
      expectedVersion: expectedVersion,
    );
    if (version == null) {
      throw const FirmwareFailure(
        'Chromatic did not report firmware versions.',
      );
    }
    return version;
  }

  Future<void> install(
    FirmwareBundle bundle,
    FirmwareRelease release,
    void Function(FirmwareProgress) report, {
    Directory? logDirectory,
  }) async {
    verifiedPort = null;
    Directory? staging;
    IOSink? log;
    var stage = 'Checking firmware';
    var mcuWritten = false;
    var fpgaWritten = false;
    try {
      final logs =
          logDirectory ??
          Directory(
            p.join(
              (await getApplicationSupportDirectory()).path,
              'firmware-logs',
            ),
          );
      await logs.create(recursive: true);
      final logFile = File(
        p.join(logs.path, 'flash-${DateTime.now().microsecondsSinceEpoch}.log'),
      );
      await logFile.writeAsString('Target: ${release.label}\n');
      logPath = logFile.path;
      log = logFile.openWrite(mode: FileMode.append);
      unawaited(log.done.catchError((Object _) {}));
      void record(String line) => log?.writeln(line);
      Future<ToolResult> run(
        String name,
        List<String> arguments, {
        bool writing = false,
        String? component,
      }) async {
        final command = [...bundle.tools[name]!, ...arguments];
        record('Command: ${jsonEncode(command)}');
        final result = await tools.run(command, (line) {
          record(line);
          if (!writing) return;
          final lower = line.toLowerCase();
          final fraction = RegExp(r'(\d+(?:\.\d+)?)\s*%').firstMatch(line);
          final percent = fraction == null
              ? null
              : double.parse(fraction[1]!) / 100;
          if (lower.contains('verif') || lower.startsWith('reading:')) {
            report(
              FirmwareProgress(
                'Verifying...',
                component: component,
                fraction: percent,
              ),
            );
          } else if (lower.startsWith('writing')) {
            report(
              FirmwareProgress(
                'Writing...',
                component: component,
                fraction: percent,
              ),
            );
          } else if (lower.startsWith('erasing:')) {
            report(
              FirmwareProgress(
                'Erasing...',
                component: component,
                fraction: percent,
              ),
            );
          }
        }, timeout: writing ? null : const Duration(seconds: 20));
        record('Exit code: ${result.exitCode}');
        if (result.exitCode != 0) {
          final lines = result.output.trim().split('\n');
          final detail = lines
              .skip(lines.length > 6 ? lines.length - 6 : 0)
              .join('\n');
          throw FirmwareFailure(
            '$name failed${detail.isEmpty ? '.' : ':\n$detail'}',
          );
        }
        return result;
      }

      report(FirmwareProgress(stage));
      staging = await Directory.systemTemp.createTemp('chromagician-firmware-');
      final mcu = await bundle.stage(release.mcu, staging, 'mcu.bin');
      final fpga = await bundle.stage(release.fpga, staging, 'fpga.fs');
      await run('esptool', ['version']);
      final image = await run('esptool', [
        '--chip',
        'esp32',
        'image_info',
        mcu.path,
      ]);
      if (!RegExp(
            r'Checksum: [0-9a-f]+ \(valid\)',
            caseSensitive: false,
          ).hasMatch(image.output) ||
          !RegExp(
            r'Validation Hash: [0-9a-f]+ \(valid\)',
            caseSensitive: false,
          ).hasMatch(image.output)) {
        throw const FirmwareFailure('The MCU application checksum is invalid.');
      }
      await run('openFPGALoader', ['--version']);
      final ports = await backend.devices();
      if (ports.length != 1) {
        throw FirmwareFailure(
          ports.isEmpty
              ? 'Power on your Chromatic and connect it by USB.'
              : 'Connect only one Chromatic while installing firmware.',
        );
      }
      final scan = await run('openFPGALoader', ['--scan-usb']);
      final probes = RegExp(
        r'^\s*(\d+)\s+(\d+)\s+0x33aa:0x0120\b',
        multiLine: true,
        caseSensitive: false,
      ).allMatches(scan.output).toList();
      if (probes.length != 1) {
        throw FirmwareFailure(
          probes.isEmpty
              ? 'The Chromatic programmer is unavailable. Check its USB connection and programmer driver.'
              : 'Connect only one Chromatic programmer while installing firmware.',
        );
      }
      final cable = ['--cable', 'gwu2x'];
      final detected = await run('openFPGALoader', [...cable, '--detect']);
      if (!RegExp(
        r'GW5A-25|0x0*1281b\b',
        caseSensitive: false,
      ).hasMatch(detected.output)) {
        throw const FirmwareFailure(
          'The connected FPGA is not the expected Chromatic device.',
        );
      }
      stage = 'MCU installation';
      report(const FirmwareProgress('Writing...', component: 'MCU'));
      final mcuResult = await run(
        'esptool',
        [
          '--chip',
          'esp32',
          '--port',
          ports.single,
          '--baud',
          '460800',
          '--before',
          'default_reset',
          '--after',
          'hard_reset',
          'write_flash',
          '--flash_mode',
          'dio',
          '--flash_freq',
          '40m',
          '--flash_size',
          '4MB',
          '0x10000',
          mcu.path,
        ],
        writing: true,
        component: 'MCU',
      );
      if (!mcuResult.output.contains('Hash of data verified.')) {
        throw const FirmwareFailure(
          'The MCU tool did not confirm its flash checksum.',
        );
      }
      mcuWritten = true;
      stage = 'FPGA installation';
      report(const FirmwareProgress('Writing...', component: 'FPGA'));
      await run(
        'openFPGALoader',
        [
          ...cable,
          '--write-flash',
          '--verify',
          '--reset',
          '--force-terminal-mode',
          fpga.path,
        ],
        writing: true,
        component: 'FPGA',
      );
      fpgaWritten = true;
      stage = 'Restart verification';
      report(const FirmwareProgress('Reconnecting...'));
      Map<String, String>? lastVersion;
      final reconnectTime = Stopwatch()..start();
      for (
        var attempt = 0;
        attempt < reconnectAttempts &&
            reconnectTime.elapsed < const Duration(seconds: 30);
        attempt++
      ) {
        await Future<void>.delayed(reconnectDelay);
        try {
          final connected = await backend.devices();
          if (connected.length != 1) continue;
          lastVersion = await readVersion(
            connected.single,
            afterFlash: true,
            expectedVersion: release.version,
          );
          record('Running firmware: ${jsonEncode(lastVersion)}');
          if ([
            'mcu',
            'fpga',
            'chromatic',
          ].every((key) => lastVersion![key] == release.version[key])) {
            verifiedPort = connected.single;
            record(
              'Installation complete; both images verified and running versions match.',
            );
            report(
              const FirmwareProgress('Installed and verified', fraction: 1),
            );
            return;
          }
        } on Object catch (error) {
          record('Waiting for restart: $error');
        }
      }
      throw FirmwareFailure(
        'Both images were written and verified, but the running versions could not be confirmed. Power-cycle your Chromatic and check Firmware in its menu.${lastVersion == null ? '' : '\nReported: ${jsonEncode(lastVersion)}'}',
      );
    } on Object catch (error) {
      final partial = mcuWritten && !fpgaWritten
          ? '\nThe MCU was updated; the FPGA still needs installation. Reconnect and retry this firmware pair.'
          : '';
      log?.writeln('$stage failed: $error$partial');
      throw FirmwareFailure('$stage: $error$partial');
    } finally {
      try {
        await log?.flush();
        await log?.close();
      } on Object {
      }
      try {
        await staging?.delete(recursive: true);
      } on Object {
      }
    }
  }
}
