import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'firmware.dart';
import 'releases.dart';

class FirmwareReleases {
  FirmwareReleases(this.client, {GitHubRelease? firmware}) {
    if (firmware != null) {
      _releases[firmwareRepository] = firmware;
    }
  }
  final ReleaseClient client;
  final _releases = <String, GitHubRelease>{};

  Future<GitHubRelease?> _latest(
    String repository, {
    bool prereleases = true,
  }) => _releases.containsKey(repository)
      ? Future.value(_releases[repository])
      : client.latest(repository, prereleases: prereleases, allowCached: true);

  Future<FirmwareRelease> describe(String id) async {
    if (id != 'chromagician' && id != 'stock') {
      throw const ReleaseFailure('Unknown firmware.');
    }
    final stock = id == 'stock';
    final release = await _latest(
      stock ? stockMcuRepository : firmwareRepository,
      prereleases: !stock,
    );
    if (release == null) {
      throw ReleaseFailure(
        'No ${stock ? 'stock firmware' : 'ChroMagic'} release is available.',
      );
    }
    _releases[stock ? stockMcuRepository : firmwareRepository] = release;
    return FirmwareRelease({
      'id': id,
      'label': '${stock ? 'Stock' : 'ChroMagic'} ${release.tag}',
      'version': {'chromatic': release.tag},
      'mcu': <String, String>{},
      'fpga': <String, String>{},
    });
  }

  Future<FirmwareBundle> prepare(
    String id,
    Map<String, List<String>> tools,
    void Function(FirmwareProgress) progress,
  ) async {
    try {
      return await _prepare(id, tools, progress);
    } on FormatException {
      throw const ReleaseFailure('The firmware release manifest is invalid.');
    } on TypeError {
      throw const ReleaseFailure(
        'The firmware release manifest is incomplete.',
      );
    } on FileSystemException {
      throw const ReleaseFailure(
        'Could not save the firmware download. Check available disk space.',
      );
    }
  }

  Future<FirmwareBundle> _prepare(
    String id,
    Map<String, List<String>> tools,
    void Function(FirmwareProgress) progress,
  ) async {
    progress(const FirmwareProgress('Checking releases...'));
    if (id == 'stock') return _stock(tools, progress);
    if (id != 'chromagician') throw const ReleaseFailure('Unknown firmware.');
    final release = await _latest(firmwareRepository);
    if (release == null) {
      throw const ReleaseFailure('No ChroMagic release is available yet.');
    }
    final manifest = await client.download(
      release,
      release.asset('firmware.json'),
      maxBytes: 65536,
    );
    final value =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    if (value['schema_version'] != 1) {
      throw const ReleaseFailure(
        'This firmware release needs a newer ChroMagician.',
      );
    }
    final versions = Map<String, String>.from(value['version'] as Map);
    if (releaseVersion(versions['chromatic'] ?? '') != release.version ||
        ![
          'mcu',
          'fpga',
          'chromatic',
        ].every((key) => versions[key]?.isNotEmpty == true)) {
      throw const ReleaseFailure(
        'The firmware version does not match its release.',
      );
    }
    final artifacts = <String, Map<String, String>>{};
    for (final component in ['mcu', 'fpga']) {
      progress(
        FirmwareProgress('Downloading...', component: component.toUpperCase()),
      );
      final entry = Map<String, String>.from(value[component] as Map);
      final hash = entry['sha256'];
      if (hash == null) {
        throw const ReleaseFailure(
          'The firmware manifest is missing a checksum.',
        );
      }
      final file = await client.download(
        release,
        release.asset(entry['file'] ?? ''),
        expectedHash: hash,
      );
      artifacts[component] = {
        'file': p.relative(file.path, from: client.cache.path),
        'sha256': hash,
        if (entry['offset'] != null) 'offset': entry['offset']!,
      };
    }
    return FirmwareBundle(client.cache, tools, [
      FirmwareRelease({
        'id': 'chromagician',
        'label': 'ChroMagic ${release.tag}',
        'version': versions,
        'mcu': artifacts['mcu'],
        'fpga': artifacts['fpga'],
      }),
    ]);
  }

  Future<FirmwareBundle> _stock(
    Map<String, List<String>> tools,
    void Function(FirmwareProgress) progress,
  ) async {
    final releases = await Future.wait([
      _latest(stockMcuRepository, prereleases: false),
      _latest(stockFpgaRepository, prereleases: false),
    ]);
    if (releases.any((r) => r == null)) {
      throw const ReleaseFailure('No stock firmware release is available.');
    }
    final mcu = releases[0]!, fpga = releases[1]!;
    ReleaseAsset singleImage(GitHubRelease release, String extension) {
      final images = release.assets
          .where((a) => a.name.endsWith(extension))
          .toList();
      if (images.length != 1) {
        throw const ReleaseFailure(
          'The stock release does not contain an unambiguous firmware image.',
        );
      }
      return images.single;
    }

    final mcuAsset = singleImage(mcu, '.bin'),
        fpgaAsset = singleImage(fpga, '.fs');
    final mcuVersion =
        RegExp(
          r'^v?\d+\.\d+\.\d+$',
        ).hasMatch(p.basenameWithoutExtension(mcuAsset.name))
        ? p.basenameWithoutExtension(mcuAsset.name)
        : null;
    if (mcuVersion == null) {
      throw const ReleaseFailure(
        'The stock MCU version could not be determined.',
      );
    }
    progress(const FirmwareProgress('Downloading...', component: 'MCU'));
    final mcuFile = await client.download(mcu, mcuAsset);
    progress(const FirmwareProgress('Downloading...', component: 'FPGA'));
    final fpgaFile = await client.download(fpga, fpgaAsset);
    return FirmwareBundle(client.cache, tools, [
      FirmwareRelease({
        'id': 'stock',
        'label': 'Stock ${mcu.tag}',
        'version': {
          'mcu': mcuVersion,
          'fpga': fpga.tag.replaceFirst(RegExp('^v'), ''),
          'chromatic': mcu.tag,
        },
        'mcu': {
          'file': p.relative(mcuFile.path, from: client.cache.path),
          'sha256': mcuAsset.digest!,
          'offset': '0x10000',
        },
        'fpga': {
          'file': p.relative(fpgaFile.path, from: client.cache.path),
          'sha256': fpgaAsset.digest!,
        },
      }),
    ]);
  }
}

Future<FirmwareBundle> firmwareToolConfiguration({String? directory}) async {
  final root = Directory(
    directory ??
        Platform.environment['CHROMATIC_FIRMWARE_DIR'] ??
        p.join(p.dirname(Platform.resolvedExecutable), 'firmware'),
  ).absolute;
  final manifest = File(p.join(root.path, 'manifest.json'));
  final tools = <String, List<String>>{
    'esptool': ['esptool'],
    'openFPGALoader': ['openFPGALoader'],
  };
  if (await manifest.exists()) {
    final data =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    tools.addAll(
      (data['tools'] as Map).map(
        (key, value) =>
            MapEntry(key as String, List<String>.from(value as List)),
      ),
    );
    if (data['portable_tools'] == true) {
      for (final name in ['esptool', 'openFPGALoader']) {
        final command = tools[name]!;
        if (command.isEmpty ||
            command.first.isEmpty ||
            p.isAbsolute(command.first)) {
          throw const FormatException('Invalid packaged firmware tool path.');
        }
        final executable = p.normalize(p.join(root.path, command.first));
        if (!p.isWithin(root.path, executable) ||
            !await File(executable).exists() ||
            !p.isWithin(
              await root.resolveSymbolicLinks(),
              await File(executable).resolveSymbolicLinks(),
            )) {
          throw const FormatException(
            'Packaged firmware tool is missing or invalid.',
          );
        }
        tools[name] = [executable, ...command.skip(1)];
      }
    }
  }
  return FirmwareBundle(root, tools, [
    for (final id in ['chromagician', 'stock'])
      FirmwareRelease({
        'id': id,
        'label': id == 'stock' ? 'Stock' : 'ChroMagic',
        'version': <String, String>{},
        'mcu': <String, String>{},
        'fpga': <String, String>{},
      }),
  ]);
}
