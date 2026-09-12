import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef BackendEvent = Map<String, dynamic>;

class BackendFailure implements Exception {
  const BackendFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

abstract class CartBackend {
  Future<List<String>> devices();
  Stream<BackendEvent> run(List<String> arguments);
  Future<Map<String, String>?> firmwareInfo(
    String port, {
    bool afterFlash = false,
    Map<String, String>? expectedVersion,
  }) async {
    Map<String, String>? version;
    await for (final event in run([
      '--firmware-info',
      '--port',
      port,
      if (afterFlash) '--after-flash',
      if (expectedVersion != null) ...[
        '--expected-firmware',
        jsonEncode(expectedVersion),
      ],
    ])) {
      if (event['event'] == 'firmware_info') {
        version = Map<String, String>.from(event['version'] as Map);
      }
    }
    return version;
  }

  Stream<BackendEvent> watch(String port) => run([
    '--inspect',
    '--port',
    port,
    '--timeout',
    '15',
    '--boot-wait-ms',
    '750',
  ]);
  Future<BackendEvent>? listSd(String port, String directory) => null;
  Future<void> stopWatching() async {}
}

class ProcessBackend extends CartBackend {
  ProcessBackend(
    this.executable, {
    this.firmwareInfoTimeout = const Duration(seconds: 15),
    this.directoryTimeout = const Duration(seconds: 35),
  });
  static const _startFailure = BackendFailure(
    'missing_backend',
    'The cartridge tools could not start. Restart ChroMagician.',
  );
  final String executable;
  final Duration firmwareInfoTimeout;
  final Duration directoryTimeout;
  bool _running = false;
  Future<Process>? _watchLaunch;
  String? _watchPort;
  bool _watchSdListing = false;
  int _directoryId = 0;
  Completer<BackendEvent>? _directoryReply;

  @override
  Stream<BackendEvent> watch(String port) {
    if (_running || _watchLaunch != null) {
      return Stream.error(
        const BackendFailure('busy', 'Cartridge tools are busy.'),
      );
    }
    final launch = Process.start(executable, [
      '--watch',
      '--port',
      port,
      '--boot-wait-ms',
      '750',
      '--json',
    ]);
    _watchLaunch = launch;
    _watchPort = port;
    _watchSdListing = false;
    return _watchEvents(launch);
  }

  Stream<BackendEvent> _watchEvents(Future<Process> launch) async* {
    Process? process;
    try {
      process = await launch;
      final stderr = process.stderr.transform(utf8.decoder).join();
      var complete = false;
      BackendFailure? failure;
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        final event = jsonDecode(line) as BackendEvent;
        if (event['schema_version'] != null && event['schema_version'] != 1) {
          throw const BackendFailure(
            'protocol_error',
            'Unsupported discovery protocol.',
          );
        }
        if (event['event'] == 'session_started') {
          _watchSdListing = event['sd_listing'] == true;
        }
        if (event['event'] == 'sd_list' || event['event'] == 'sd_list_error') {
          final reply = _directoryReply;
          if (event['id'] == _directoryId &&
              reply != null &&
              !reply.isCompleted) {
            if (event['event'] == 'sd_list_error') {
              reply.completeError(
                BackendFailure(
                  event['code'] as String,
                  event['message'] as String,
                ),
              );
            } else {
              reply.complete(event);
            }
          }
          continue;
        }
        if (event['event'] == 'error') {
          failure = BackendFailure(
            event['code'] as String,
            event['message'] as String,
          );
        } else if (event['event'] == 'complete') {
          complete = true;
        } else {
          yield event;
        }
      }
      final exitCode = await process.exitCode;
      final diagnostic = await stderr;
      if (failure != null) throw failure;
      if (exitCode != 0 || !complete) {
        throw BackendFailure(
          'transport_error',
          diagnostic.trim().isEmpty
              ? 'Cartridge discovery disconnected.'
              : diagnostic.trim(),
        );
      }
    } on ProcessException {
      throw _startFailure;
    } finally {
      if (identical(_watchLaunch, launch)) {
        _failDirectoryRequest();
        _watchSdListing = false;
      }
      if (process != null) {
        await process.stdin.close();
        await process.exitCode;
      }
      if (identical(_watchLaunch, launch)) _watchLaunch = null;
    }
  }

  void _failDirectoryRequest() {
    final reply = _directoryReply;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(
        const BackendFailure(
          'sd_listing',
          'The connection closed before the folder could be read.',
        ),
      );
    }
  }

  @override
  Future<BackendEvent>? listSd(String port, String directory) {
    final launch = _watchLaunch;
    if (_running || launch == null || _watchPort != port || !_watchSdListing) {
      return null;
    }
    if (_directoryReply != null) {
      return Future.error(
        const BackendFailure('busy', 'A folder is already loading.'),
      );
    }
    final reply = Completer<BackendEvent>();
    final id = ++_directoryId;
    _directoryReply = reply;
    final result = reply.future
        .timeout(
          directoryTimeout,
          onTimeout: () {
            _watchSdListing = false;
            unawaited(
              launch.then((process) {
                process.kill();
              }),
            );
            throw const BackendFailure(
              'sd_listing',
              'The SD card did not respond.',
            );
          },
        )
        .then((event) {
          if (event['path'] != directory) {
            throw const BackendFailure(
              'protocol_error',
              'The SD folder response did not match the request.',
            );
          }
          return event;
        })
        .whenComplete(() {
          if (identical(_directoryReply, reply)) _directoryReply = null;
        });
    unawaited(_sendDirectoryRequest(launch, id, directory, reply));
    return result;
  }

  Future<void> _sendDirectoryRequest(
    Future<Process> launch,
    int id,
    String directory,
    Completer<BackendEvent> reply,
  ) async {
    try {
      final process = await launch;
      if (!identical(_watchLaunch, launch) || !_watchSdListing) {
        _failDirectoryRequest();
        return;
      }
      process.stdin.writeln(jsonEncode({'id': id, 'path': directory}));
      await process.stdin.flush();
    } on Object catch (error) {
      if (!reply.isCompleted) reply.completeError(error);
    }
  }

  @override
  Future<void> stopWatching() async {
    final launch = _watchLaunch;
    if (launch == null) return;
    _watchSdListing = false;
    _failDirectoryRequest();
    try {
      final process = await launch;
      await process.stdin.close();
      await process.exitCode;
    } on ProcessException {}
  }

  static String resolveExecutable() {
    final override = Platform.environment['CHROMATIC_BACKUP_BIN'];
    if (override != null && override.isNotEmpty) return override;
    final name = Platform.isWindows
        ? 'chromatic-backup.exe'
        : 'chromatic-backup';
    final packaged = p.join(
      p.dirname(Platform.resolvedExecutable),
      'libexec',
      name,
    );
    if (File(packaged).existsSync()) return packaged;
    final development = p.normalize(
      p.join(Directory.current.path, '..', 'target', 'release', name),
    );
    if (File(development).existsSync()) return development;
    throw const BackendFailure(
      'missing_backend',
      'The cartridge tools are missing from this app. Build or install the complete desktop bundle.',
    );
  }

  @override
  Future<List<String>> devices() async {
    final ProcessResult result;
    try {
      result = await Process.run(executable, ['--devices', '--json']);
    } on ProcessException {
      throw _startFailure;
    }
    if (result.exitCode != 0) {
      throw BackendFailure('device_discovery', result.stdout.toString().trim());
    }
    final event = jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
    if (event['schema_version'] != 1 || event['event'] != 'devices') {
      throw const BackendFailure(
        'protocol_error',
        'The bundled cartridge tools need updating.',
      );
    }
    return List<String>.from(event['ports'] as List);
  }

  @override
  Stream<BackendEvent> run(List<String> arguments) async* {
    if (_running) {
      throw const BackendFailure(
        'busy',
        'A cartridge operation is already running.',
      );
    }
    _running = true;
    Process? process;
    Future<String>? stderr;
    var completed = false;
    var firmwareInfoTimedOut = false;
    Timer? firmwareInfoTimer;
    BackendFailure? failure;
    try {
      await stopWatching();
      process = await Process.start(executable, [...arguments, '--json']);
      if (arguments.contains('--firmware-info')) {
        final probe = process;
        firmwareInfoTimer = Timer(firmwareInfoTimeout, () {
          firmwareInfoTimedOut = true;
          probe.kill(ProcessSignal.sigkill);
        });
        unawaited(probe.exitCode.then((_) => firmwareInfoTimer?.cancel()));
      }
      stderr = process.stderr.transform(utf8.decoder).join();
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        BackendEvent event;
        try {
          event = jsonDecode(line) as BackendEvent;
        } on Object {
          failure ??= const BackendFailure(
            'protocol_error',
            'The cartridge tools returned an unreadable response.',
          );
          continue;
        }
        if (event['schema_version'] != null && event['schema_version'] != 1) {
          failure ??= const BackendFailure(
            'protocol_error',
            'The app and cartridge tools use different protocol versions.',
          );
        }
        if (event['event'] == 'error') {
          failure = BackendFailure(
            event['code'] as String? ?? 'device_error',
            event['message'] as String? ?? 'The cartridge operation failed.',
          );
        }
        if (event['event'] == 'complete') {
          completed = true;
          continue;
        }
        yield event;
      }
      final exitCode = await process.exitCode;
      final diagnostic = await stderr;
      if (firmwareInfoTimedOut) {
        throw const BackendFailure(
          'firmware_timeout',
          'Chromatic did not respond to the firmware check.',
        );
      }
      if (failure != null) throw failure;
      if (exitCode != 0 || !completed) {
        throw BackendFailure(
          'incomplete',
          diagnostic.trim().isNotEmpty
              ? diagnostic.trim()
              : 'The operation ended before verification completed. Reconnect and try again.',
        );
      }
      yield {'event': 'complete'};
    } on ProcessException {
      throw _startFailure;
    } finally {
      if (process != null) await process.exitCode;
      firmwareInfoTimer?.cancel();
      _running = false;
    }
  }
}
