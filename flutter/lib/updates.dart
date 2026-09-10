import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'releases.dart';
import 'app_update.dart';

class ReleaseUpdates extends ChangeNotifier {
  ReleaseUpdates(this.client, this.appVersion, {AppInstaller? installer})
    : installer = installer ?? AppUpdater(client);
  final ReleaseClient client;
  final String appVersion;
  final AppInstaller installer;
  bool restoredPreviousVersion =
      Platform.environment['CHROMAGIC_UPDATE_FAILED'] == '1';
  GitHubRelease? appUpdate, firmware;
  bool _disposed = false;

  static Future<ReleaseUpdates> configured() async {
    final root = await getApplicationSupportDirectory();
    final info = await PackageInfo.fromPlatform();
    return ReleaseUpdates(
      ReleaseClient(Directory(p.join(root.path, 'releases'))),
      info.version,
    );
  }

  File get _preferences => File(p.join(client.cache.path, 'preferences.json'));
  Future<void> check() async {
    String? ignored;
    try {
      ignored =
          (jsonDecode(await _preferences.readAsString())
                  as Map)['ignored_app_release']
              as String?;
    } on Object {
    }
    await Future.wait([
      (() async {
        try {
          final release = await client.latest(appRepository);
          final installed = releaseVersion(appVersion);
          if (!_disposed &&
              release != null &&
              installed != null &&
              release.version! > installed &&
              release.tag != ignored) {
            appUpdate = release;
            notifyListeners();
          }
        } on Object {
        }
      })(),
      (() async {
        try {
          final release = await client.latest(firmwareRepository);
          if (!_disposed) {
            firmware = release;
            notifyListeners();
          }
        } on Object {
        }
      })(),
    ]);
  }

  bool firmwareAvailable(
    Map<String, String>? installed, {
    required bool hasChroMagic,
  }) {
    if (firmware == null || installed == null || !hasChroMagic) return false;
    final name = installed['chromatic'] ?? '';
    if (RegExp(r'^4\.2\s+CM$', caseSensitive: false).hasMatch(name)) {
      return true;
    }
    final version = releaseVersion(name);
    return version != null && firmware!.version! > version;
  }

  Future<void> ignore(GitHubRelease release) async {
    await _preferences.parent.create(recursive: true);
    await _preferences.writeAsString(
      jsonEncode({'ignored_app_release': release.tag}),
      flush: true,
    );
    appUpdate = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
