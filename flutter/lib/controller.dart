import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'backend.dart';
import 'catalog.dart';

enum CartAction {
  backupGame('Back up game', '--rom', false),
  writeGame('Write Homebrew', '--write-rom', true),
  backupSave('Back up save', '--sav', false),
  restoreSave('Restore save', '--write-sav', true);

  const CartAction(this.label, this.flag, this.writes);
  final String label;
  final String flag;
  final bool writes;
  bool get isGame => this == backupGame || this == writeGame;
}

class CartController extends ChangeNotifier {
  CartController(this.backend, {this.catalog});
  final CartBackend backend;
  final CartCatalog? catalog;
  GameMetadata? game;
  bool metadataLoading = false;
  int _metadataGeneration = 0;
  List<String> ports = [];
  String? port;
  Map<String, String>? firmwareVersion;
  bool _firmwareChecked = false;
  Future<Map<String, String>?>? _firmwareQuery;
  Map<String, dynamic>? cartridge;
  bool? pcModeEnabled;
  bool _retriedFirmwareOnWake = false;
  bool sdPresent = false;
  bool sdChecked = false;
  String? sdError;
  int sdGeneration = 0;
  bool showingSd = false;
  bool sdLoading = false;
  String sdDirectory = '/';
  List<Map<String, dynamic>> sdEntries = [];

  CartAction action = CartAction.backupGame;
  String? path;
  bool busy = false;
  bool inspecting = false;
  bool firmwareOpen = false;
  bool finished = false;
  String phase = 'Ready when you are';
  double? progress;
  int bytes = 0;
  int total = 0;
  String? checksum;
  String? error;
  final List<String> activity = [];
  Timer? _poll;
  bool _discovering = false;
  String? _discoveryError;
  bool _hasScanned = false;
  bool _disposed = false;
  bool _appUpdatePaused = false;
  bool _automatic = false;
  StreamSubscription<BackendEvent>? _watch;
  Completer<void>? _watchFirst;
  int _watchGeneration = 0;
  DateTime _nextWatchAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get cartridgeReady => port != null && cartridge != null;
  static bool _isChroMagic(Map<String, String>? version) => RegExp(
    r'(^|\W)CM($|\W)|CHROMAGIC|^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)? \(\d+\.\d+\)$',
    caseSensitive: false,
  ).hasMatch(version?['chromatic'] ?? '');
  bool get hasChroMagic =>
      _isChroMagic(firmwareVersion) ||
      pcModeEnabled != null ||
      cartridge != null;
  bool get requiresFirmwareInstall => firmwareVersion != null && !hasChroMagic;
  bool get showFirmwareSetup =>
      port != null && !hasChroMagic && (!inspecting || requiresFirmwareInstall);
  bool get needsPcMode => hasChroMagic && pcModeEnabled != true;
  String get sdStatusMessage => switch (sdError) {
    null => 'No SD card installed',
    'ESP_ERR_TIMEOUT' => 'The SD card is not responding',
    'ESP_ERR_INVALID_STATE' => 'The SD card is busy',
    _ => 'Could not read the SD card',
  };

  void clearFirmwareVersion() {
    firmwareVersion = null;
    _firmwareChecked = false;
    pcModeEnabled = null;
    _retriedFirmwareOnWake = false;
    sdChecked = false;
    sdError = null;
  }

  void setFirmwareVersion(Map<String, String> version) {
    firmwareVersion = Map.of(version);
    _firmwareChecked = true;
    if (!_isChroMagic(version)) {
      pcModeEnabled = null;
      sdChecked = false;
      sdError = null;
      cartridge = null;
      _clearMetadata();
      sdGeneration++;
      sdPresent = showingSd = false;
      sdEntries = [];
      sdDirectory = '/';
      clearTransfer();
    }
    _notify();
  }

  bool get hasTransfer =>
      !firmwareOpen &&
      port != null &&
      ((busy && !inspecting && !sdLoading) || activity.isNotEmpty);

  bool get loadingGame =>
      !hasTransfer &&
      (((cartridge == null && inspecting && !needsPcMode) ||
              (game == null && metadataLoading)) ||
          (port == null && !_hasScanned));

  String get title => game?.title ?? rawTitle;
  String get rawTitle =>
      (cartridge?['title'] as String?)?.trim().isNotEmpty == true
      ? (cartridge!['title'] as String).trim()
      : 'Unknown game';
  String get suggestedName {
    final name = [game?.releaseName, game?.title, cartridge?['title']]
        .whereType<String>()
        .map((name) => name.trim())
        .firstWhere((name) => name.isNotEmpty, orElse: () => 'cartridge');
    final stem = _fileStem(name);
    return '$stem.${action.isGame ? (cartridge?['color'] == true ? 'gbc' : 'gb') : 'sav'}';
  }

  bool get canWriteGame => cartridgeReady && cartridge?['rom_writable'] == true;
  bool actionAvailable(CartAction value) =>
      value != CartAction.writeGame || canWriteGame;
  bool get canStart =>
      port != null &&
      path != null &&
      !busy &&
      !firmwareOpen &&
      actionAvailable(action);

  Future<void> startDiscovery() async {
    _automatic = true;
    _poll?.cancel();
    if (!_disposed) {
      _poll = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => unawaited(refreshDevices()),
      );
    }
    await refreshDevices();
  }

  Future<void> refreshDevices() async {
    if (_disposed ||
        _appUpdatePaused ||
        _discovering ||
        (firmwareOpen && busy)) {
      return;
    }
    _discovering = true;
    Future<void>? inspection;
    try {
      final discovered = await backend.devices();
      if (_disposed || _appUpdatePaused || (firmwareOpen && busy)) return;
      if (_discoveryError != null && error == _discoveryError) error = null;
      _discoveryError = null;
      ports = discovered;
      if (port != null && !ports.contains(port)) {
        port = null;
        clearFirmwareVersion();
        sdGeneration++;
        sdPresent = showingSd = false;
        sdEntries = [];
        sdDirectory = '/';
        cartridge = null;
        _clearMetadata();
        clearTransfer();
        if (inspecting) busy = inspecting = false;
        phase = 'Chromatic disconnected';
        _notify();
        await _stopWatching();
      }
      if (firmwareOpen) {
        if (port == null && ports.length == 1) port = ports.single;
        return;
      }
      if (busy) return;
      if (port == null && ports.length == 1) {
        port = ports.single;
        inspection = inspect();
      } else if (_automatic &&
          port != null &&
          !requiresFirmwareInstall &&
          _watch == null &&
          DateTime.now().isAfter(_nextWatchAttempt)) {
        inspection = inspect(keepTransferResult: true);
      }
      _notify();
    } on Object catch (failure) {
      error = _discoveryError = friendlyError(failure);
      _notify();
    } finally {
      _discovering = false;
      _hasScanned = true;
      _notify();
    }
    try {
      await inspection;
    } on Object catch (failure) {
      if (!_disposed) {
        error = friendlyError(failure);
        _notify();
      }
    }
  }

  Future<void> selectPort(String selected) async {
    if (busy || firmwareOpen) return;
    port = selected;
    clearFirmwareVersion();
    sdGeneration++;
    sdPresent = showingSd = false;
    sdDirectory = '/';
    sdEntries = [];
    cartridge = null;
    _clearMetadata();
    await inspect();
  }

  Future<void> _stopWatching() async {
    _watchGeneration++;
    final first = _watchFirst;
    if (first != null && !first.isCompleted) first.complete();
    await backend.stopWatching();
    final subscription = _watch;
    _watch = null;
    await subscription?.cancel();
  }

  Future<void> stopDiscovery() async {
    _automatic = false;
    _poll?.cancel();
    await _stopWatching();
  }

  Future<void> pauseForAppUpdate() async {
    if (firmwareOpen || (busy && !inspecting)) {
      throw StateError('A transfer is in progress.');
    }
    _appUpdatePaused = true;
    await stopDiscovery();
    try {
      await _firmwareQuery;
    } on Object {
    }
    busy = inspecting = false;
  }

  Future<void> resumeAfterAppUpdate() async {
    if (!_appUpdatePaused || _disposed) return;
    _appUpdatePaused = false;
    await startDiscovery();
  }

  Future<bool> beginFirmware() async {
    if (port == null || firmwareOpen || (busy && !inspecting)) return false;
    firmwareOpen = true;
    _notify();
    try {
      await _stopWatching();
      try {
        await _firmwareQuery;
      } on Object {
      }
      busy = inspecting = false;
      _notify();
      return true;
    } on Object {
      firmwareOpen = false;
      rethrow;
    }
  }

  void setFirmwareBusy(bool value) {
    if (!firmwareOpen) return;
    busy = value;
    _notify();
  }

  Future<void> endFirmware() async {
    firmwareOpen = false;
    busy = inspecting = false;
    clearTransfer();
    _nextWatchAttempt = DateTime.fromMillisecondsSinceEpoch(0);
    _notify();
    if (_automatic) await refreshDevices();
  }

  Future<void> inspect({bool keepTransferResult = false}) async {
    if (busy ||
        _appUpdatePaused ||
        port == null ||
        _disposed ||
        firmwareOpen ||
        _firmwareQuery != null) {
      return;
    }
    if (!keepTransferResult) clearTransfer();
    busy = inspecting = true;
    if (!keepTransferResult) {
      cartridge = null;
      _clearMetadata();
      phase = 'Reading cartridge';
    }
    _notify();
    await _stopWatching();
    if (_disposed || _appUpdatePaused || port == null || firmwareOpen) return;
    final generation = _watchGeneration;
    final selectedPort = port!;
    if (!_firmwareChecked) {
      final query = backend.firmwareInfo(selectedPort);
      _firmwareQuery = query;
      try {
        final version = await query;
        if (_disposed ||
            firmwareOpen ||
            generation != _watchGeneration ||
            port != selectedPort) {
          return;
        }
        if (version != null) setFirmwareVersion(version);
      } on Object {
      } finally {
        if (identical(_firmwareQuery, query)) _firmwareQuery = null;
      }
    }
    if (_disposed ||
        firmwareOpen ||
        generation != _watchGeneration ||
        port != selectedPort) {
      return;
    }
    if (requiresFirmwareInstall) {
      busy = inspecting = false;
      _notify();
      return;
    }
    if (!hasChroMagic) {
      busy = inspecting = false;
      _notify();
    }
    final first = Completer<void>();
    var firstSample = true;
    _watchFirst = first;
    bool current() =>
        !_disposed && generation == _watchGeneration && port == selectedPort;
    void ready() {
      if (inspecting) busy = inspecting = false;
      if (!first.isCompleted) first.complete();
      _notify();
    }

    void unavailable() {
      if (!current()) return;
      final lostGame = cartridge != null;
      cartridge = null;
      _clearMetadata();
      if (lostGame && !showingSd) clearTransfer();
      if (!showingSd) phase = 'Waiting for a game cartridge';
      firstSample = false;
      ready();
    }

    _watch = backend
        .watch(selectedPort)
        .listen(
          (event) {
            if (!current()) return;
            if (event['event'] == 'device_status') {
              final enabled = event['enabled'] as bool?;
              if (enabled != null) pcModeEnabled = enabled;
              if (enabled != true) ready();
              if (pcModeEnabled == false) {
                sdGeneration++;
                sdPresent = showingSd = sdChecked = false;
                sdError = null;
                sdEntries = [];
                sdDirectory = '/';
              }
              _notify();
              if (enabled != null &&
                  !_firmwareChecked &&
                  !_retriedFirmwareOnWake) {
                _retriedFirmwareOnWake = true;
                ready();
                unawaited(inspect(keepTransferResult: true));
              }
            } else if (event['event'] == 'sd_status') {
              final present = event['present'] == true;
              if (present != sdPresent) sdGeneration++;
              sdPresent = present;
              sdChecked = true;
              sdError = event['error'] as String?;
              if (!sdPresent) {
                if (showingSd) clearTransfer();
                showingSd = false;
                sdEntries = [];
                sdDirectory = '/';
              }
              _notify();
            } else if (event['event'] == 'cartridge_unavailable') {
              unavailable();
            } else if (event['event'] == 'cartridge_inspected') {
              pcModeEnabled = true;
              final next = Map<String, dynamic>.from(event['cartridge'] as Map);
              final same = sameCartridge(cartridge, next);
              if (!showingSd &&
                  !same &&
                  cartridge != null &&
                  !(keepTransferResult && firstSample)) {
                clearTransfer();
              }
              if (!mapEquals(cartridge, next)) {
                cartridge = next;
                if (!actionAvailable(action)) {
                  action = CartAction.backupGame;
                  path = null;
                }
                if (!same) {
                  _clearMetadata();
                  unawaited(refreshMetadata());
                }
              }
              firstSample = false;
              if (!hasTransfer) phase = 'Cartridge ready';
              ready();
            }
          },
          onError: (Object _) {
            if (!current()) return;
            _watch = null;
            clearTransfer();
            _nextWatchAttempt = DateTime.now().add(const Duration(seconds: 2));
            unavailable();
          },
          onDone: () {
            if (!current()) return;
            _watch = null;
            _nextWatchAttempt = DateTime.now().add(const Duration(seconds: 2));
            if (!first.isCompleted) unavailable();
          },
          cancelOnError: true,
        );
    await first.future;
  }

  Future<void> showSd(bool value) async {
    if (busy || firmwareOpen || (value && !sdPresent && sdError == null)) {
      return;
    }
    if (showingSd != value) clearTransfer();
    showingSd = value;
    _notify();
    if (value && sdPresent) await listSd(sdDirectory);
  }

  Future<void> listSd(String directory) =>
      sdCommand(['--sd-list', directory], listing: true);

  Future<void> backupToSd() async {
    if (busy ||
        firmwareOpen ||
        !cartridgeReady ||
        !sdPresent ||
        action.writes) {
      return;
    }
    await sdCommand([
      action.isGame ? '--sd-backup-rom' : '--sd-backup-sav',
      '/CHROMAGIC/BACKUPS/$suggestedName',
    ]);
  }

  String sdPath(String name) => p.posix.join(sdDirectory, name);

  Future<List<Map<String, dynamic>>> readSdDirectory(String directory) async {
    List<Map<String, dynamic>>? entries;
    await sdCommand(
      ['--sd-list', directory],
      listing: true,
      onListing: (result) => entries = result,
    );
    if (entries == null) {
      throw BackendFailure('sd_listing', error ?? 'Could not open the folder.');
    }
    return entries!;
  }

  Future<void> sdCommand(
    List<String> arguments, {
    bool listing = false,
    void Function(List<Map<String, dynamic>>)? onListing,
  }) async {
    if (busy || firmwareOpen || port == null || !sdPresent) return;
    final selectedPort = port!;
    final generation = sdGeneration;
    var sharedListing = false;
    busy = true;
    sdLoading = listing;
    if (!listing) {
      clearTransfer();
      phase = arguments.contains('--sd-move')
          ? 'Moving...'
          : arguments.contains('--sd-delete-many')
          ? 'Deleting...'
          : 'Connecting to SD card';
    }
    error = null;
    _notify();
    try {
      final response = listing && _watch != null
          ? backend.listSd(selectedPort, arguments[1])
          : null;
      sharedListing = response != null;
      if (!sharedListing) await _stopWatching();
      if (_disposed || port != selectedPort) return;
      final events = response != null
          ? Stream.fromFuture(response)
          : backend.run([
              ...arguments,
              '--port',
              selectedPort,
              '--boot-wait-ms',
              '750',
              '--timeout',
              '1800',
            ]);
      await for (final event in events) {
        if (port != selectedPort || (listing && generation != sdGeneration)) {
          continue;
        }
        if (event['event'] == 'sd_list') {
          final entries = (event['entries'] as List)
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList();
          if (onListing != null) {
            onListing(entries);
          } else {
            sdDirectory = event['path'] as String;
            sdEntries = entries;
          }
        } else if (!listing) {
          _consume(event);
          if (event['event'] == 'complete') phase = 'Complete';
        }
        _notify();
      }
    } on Object catch (failure) {
      if (port != selectedPort) return;
      error = friendlyError(failure);
      if (!listing) {
        finished = false;
        phase = 'Transfer needs attention';
        activity.add('Failed: $error');
      }
    } finally {
      busy = sdLoading = false;
      _notify();
    }
    if (!sharedListing && _automatic && !_disposed && port != null) {
      await inspect(keepTransferResult: true);
    }
  }

  void selectAction(CartAction value) {
    if (busy || firmwareOpen || action == value || !actionAvailable(value)) {
      return;
    }
    action = value;
    path = null;
    clearTransfer();
    _notify();
  }

  void chooseFile(String value) {
    if (busy || firmwareOpen) return;
    path = value;
    clearTransfer();
    _notify();
  }

  void clearTransfer() {
    error = checksum = progress = null;
    bytes = total = 0;
    finished = false;
    phase = 'Ready when you are';
    activity.clear();
  }

  Future<void> transfer({bool replaceOutput = false}) async {
    if (!canStart) return;
    final selectedPort = port!;
    clearTransfer();
    busy = true;
    phase = 'Connecting to Chromatic';
    _notify();
    final arguments = [
      action.flag,
      path!,
      '--port',
      selectedPort,
      if (action.writes) '--yes',
      if (replaceOutput && !action.writes) '--force',
    ];
    try {
      await _stopWatching();
      if (_disposed || port != selectedPort) return;
      await for (final event in backend.run(arguments)) {
        if (port != selectedPort) continue;
        _consume(event);
        _notify();
      }
      if (!finished) {
        throw const BackendFailure(
          'incomplete',
          'Verification did not finish.',
        );
      }
    } on Object catch (failure) {
      if (port != selectedPort) return;
      error = friendlyError(failure);
      finished = false;
      phase = 'Transfer needs attention';
      activity.add('Failed: $error');
    } finally {
      busy = false;
      _notify();
    }
    if (!_disposed &&
        port != null &&
        (_automatic || (action == CartAction.writeGame && finished))) {
      await inspect(keepTransferResult: true);
    }
  }

  void _consume(BackendEvent event) {
    final name = event['event'];
    switch (name) {
      case 'cartridge_detected':
        final next = Map<String, dynamic>.from(event['cartridge'] as Map);
        final same = sameCartridge(cartridge, next);
        cartridge = {...?(same ? cartridge : null), ...next};
        if (!same) {
          _clearMetadata();
          unawaited(refreshMetadata());
        }
      case 'rom_validated':
        checksum = event['crc32'] as String?;
        activity.add(
          'ROM checksums passed · ${formatBytes(event['size'] as int)}',
        );
      case 'flash_detected':
        activity.add('Rewritable cartridge identified');
      case 'erase_started':
        phase = 'Erasing cartridge';
        progress = null;
        activity.add(phase);
      case 'artifact_started':
        phase = event['kind'] == 'rtc'
            ? 'Reading clock data'
            : 'Reading ${event['kind'] == 'rom' ? 'game' : 'save'}';
        progress = 0;
        bytes = 0;
        total = event['size'] as int;
        activity.add(phase);
      case 'validation_started':
        phase = 'Checking save before writing';
        progress = null;
        activity.add(phase);
      case 'write_started':
        phase = 'Writing and verifying save';
        progress = 0;
        activity.add(phase);
      case 'progress':
        final next = switch (event['phase']) {
          'program' => 'Writing...',
          'verify' => showingSd ? 'Verifying file' : 'Verifying...',
          'sd_read' => 'Copying to PC',
          'sd_write' => 'Copying to SD card',
          'sd_backup' => 'Backing up to SD card',
          'sd_verify' => 'Verifying SD backup',
          _ => phase,
        };
        if (next != phase) activity.add(next);
        phase = next;
        bytes =
            (event['completed'] ?? event['received'] ?? event['written'])
                as int;
        total = event['total'] as int;
        progress = total > 0 ? (bytes / total).clamp(0.0, 1.0) : 0;
      case 'artifact_verified':
        checksum = event['crc32'] as String?;
        if (event['kind'] == 'rom') unawaited(refreshMetadata(crc32: checksum));
        activity.add('${event['kind']} verified · CRC32 $checksum');
      case 'complete':
        finished = true;
        progress = 1;
        phase = 'Complete and verified';
        activity.add(phase);
    }
  }

  static bool sameCartridge(
    Map<String, dynamic>? previous,
    Map<String, dynamic> next,
  ) {
    if (previous == null) return false;
    for (final field in [
      'title',
      'rom_size',
      'color',
      'cartridge_type',
      'save_size',
      'global_checksum',
      'header_checksum',
      'rom_version',
      'header_sha1',
    ]) {
      if (previous[field] != null &&
          next[field] != null &&
          previous[field] != next[field]) {
        return false;
      }
    }
    return true;
  }

  static String friendlyError(Object failure) {
    if (failure is BackendFailure) {
      if (failure.message.contains('SD card:')) {
        if (failure.message.contains('ESP_ERR_INVALID_STATE')) {
          return 'The destination already exists or the SD card is busy. Choose another name and try again.';
        }
        if (failure.message.contains('ESP_ERR_NOT_FOUND')) {
          return 'No SD card installed.';
        }
        if (failure.message.contains('ESP_ERR_TIMEOUT')) {
          return 'The SD card is not responding.';
        }
        if (failure.message.contains('ESP_ERR_INVALID_CRC')) {
          return 'File verification failed. Please try the copy again.';
        }
        return failure.message;
      }
      if (failure.code == 'timeout' ||
          failure.message.contains('ESP_ERR_INVALID_STATE')) {
        return 'Enable C. MAGICIAN in your Chromatic’s System settings.';
      }
      if (failure.code == 'device_not_found') {
        return 'Connect your Chromatic by USB.';
      }
      if (failure.message.contains('no physical RTC was confirmed')) {
        return 'Clock data could not be restored because this cartridge did not expose a working clock.';
      }
    }
    return failure.toString();
  }

  void _clearMetadata() {
    _metadataGeneration++;
    game = null;
    metadataLoading = false;
  }

  Future<void> refreshMetadata({String? crc32}) async {
    if (catalog == null || cartridge == null || _disposed) return;
    final generation = ++_metadataGeneration;
    final header = Map<String, dynamic>.of(cartridge!);
    metadataLoading = true;
    _notify();
    try {
      final result = await catalog!.lookup(header, crc32: crc32);
      if (generation == _metadataGeneration && !_disposed && result != null) {
        game = result;
      }
    } on Object {
    } finally {
      if (generation == _metadataGeneration && !_disposed) {
        metadataLoading = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stopDiscovery());
    _metadataGeneration++;
    catalog?.dispose();
    _poll?.cancel();
    super.dispose();
  }
}

String _fileStem(String name) {
  var stem = name.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_');
  final safe = StringBuffer();
  var bytes = 0;
  for (final rune in stem.runes) {
    final character = String.fromCharCode(rune);
    bytes += utf8.encode(character).length;
    if (bytes > 240) break;
    safe.write(character);
  }
  stem = safe.toString().trim().replaceFirst(RegExp(r'[. ]+$'), '');
  if (stem.isEmpty) return 'cartridge';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(stem)) {
    stem = '_$stem';
  }
  return stem;
}

String formatBytes(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(bytes % (1024 * 1024) == 0 ? 0 : 1)} MiB'
    : bytes >= 1024
    ? '${(bytes / 1024).toStringAsFixed(bytes % 1024 == 0 ? 0 : 1)} KiB'
    : '$bytes B';
