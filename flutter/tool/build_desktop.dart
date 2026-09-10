import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final app = p.dirname(p.dirname(Platform.script.toFilePath()));
  final workspace = p.dirname(app);
  final settings = File(p.join(app, '.dart_tool', 'desktop_build.json'));
  String? catalogDirectory = Platform.environment['CHROMATIC_CATALOG_DIR'];
  String? catalogUrl = Platform.environment['CHROMATIC_CATALOG_URL'];
  String? firmwareDirectory = Platform.environment['CHROMATIC_FIRMWARE_DIR'];
  for (var i = 0; i < arguments.length; i += 2) {
    if (i + 1 >= arguments.length) throw ArgumentError('Missing option value.');
    switch (arguments[i]) {
      case '--firmware-dir':
        firmwareDirectory = arguments[i + 1];
      case '--catalog-dir':
        catalogDirectory = arguments[i + 1];
      case '--catalog-url':
        catalogUrl = arguments[i + 1];
      default:
        throw ArgumentError('Unknown build option: ${arguments[i]}');
    }
  }
  if (catalogDirectory == null && catalogUrl == null && settings.existsSync()) {
    final previous =
        jsonDecode(await settings.readAsString()) as Map<String, dynamic>;
    catalogDirectory = previous['catalog_directory'] as String?;
    catalogUrl = previous['catalog_url'] as String?;
  }
  if (firmwareDirectory == null && settings.existsSync()) {
    final previous =
        jsonDecode(await settings.readAsString()) as Map<String, dynamic>;
    firmwareDirectory = previous['firmware_directory'] as String?;
  }
  if (Platform.isLinux) {
    firmwareDirectory = p.join(app, '.dart_tool', 'linux-tools');
  }
  if (Platform.isWindows) {
    firmwareDirectory ??= p.join(app, '.dart_tool', 'windows-tools');
    final manifest = File(p.join(firmwareDirectory, 'manifest.json'));
    if (!manifest.existsSync() ||
        (jsonDecode(manifest.readAsStringSync()) as Map)['portable_tools'] !=
            true) {
      throw ArgumentError(
        'Windows builds require the portable Windows flashing tools. '
        'Run python3 tool/package_windows_tools.py first.',
      );
    }
  }
  if (firmwareDirectory != null &&
      !Platform.isLinux &&
      !File(p.join(firmwareDirectory, 'manifest.json')).existsSync()) {
    throw ArgumentError('Firmware directory does not contain manifest.json.');
  }
  if (catalogDirectory != null &&
      !File(
        p.join(catalogDirectory, 'catalog/v1/manifest.json'),
      ).existsSync()) {
    throw ArgumentError(
      'Catalog directory does not contain catalog/v1/manifest.json.',
    );
  }
  final platform = Platform.isLinux
      ? 'linux'
      : Platform.isMacOS
      ? 'macos'
      : Platform.isWindows
      ? 'windows'
      : null;
  if (platform == null) {
    throw UnsupportedError('A desktop operating system is required.');
  }
  Future<void> run(
    String executable,
    List<String> arguments,
    String cwd, {
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: cwd,
      environment: environment,
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
    final result = await process.exitCode;
    if (result != 0) {
      throw ProcessException(executable, arguments, 'Build failed', result);
    }
  }

  if (Platform.isLinux) {
    await run('python3', [
      'tool/package_linux_tools.py',
      '--output',
      firmwareDirectory!,
    ], app);
  }
  final cargoHome =
      Platform.environment['CARGO_HOME'] ??
      p.join(
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME']!,
        '.cargo',
      );
  final rustFlags = [
    if (Platform.environment['CARGO_ENCODED_RUSTFLAGS'] case final String flags)
      ...flags.split('\u001f')
    else if (Platform.environment['RUSTFLAGS'] case final String flags)
      ...flags.split(RegExp(r'\s+')).where((flag) => flag.isNotEmpty),
    '--remap-path-prefix=$workspace=/src/chromagician',
    '--remap-path-prefix=$cargoHome=/cargo',
  ];
  await run(
    'cargo',
    ['build', '--release', '--locked'],
    workspace,
    environment: {'CARGO_ENCODED_RUSTFLAGS': rustFlags.join('\u001f')},
  );
  await run('flutter', [
    'build',
    platform,
    '--release',
    if (Platform.isLinux) '--config-only',
    if (catalogUrl != null) '--dart-define=CHROMATIC_CATALOG_URL=$catalogUrl',
  ], app);
  final arch = [Abi.linuxArm64, Abi.windowsArm64].contains(Abi.current())
      ? 'arm64'
      : 'x64';
  final installedDirectory = switch (platform) {
    'linux' => p.join(app, 'build', 'linux', arch, 'release', 'bundle'),
    'windows' => p.join(app, 'build', 'windows', arch, 'runner', 'Release'),
    _ => p.join(
      app,
      'build',
      'macos',
      'Build',
      'Products',
      'Release',
      'chromatic_pc_backup.app',
      'Contents',
      'MacOS',
    ),
  };
  var directory = installedDirectory;
  if (Platform.isLinux) {
    final staging = Directory(p.join(app, '.dart_tool', 'desktop-stage'));
    if (staging.existsSync()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    await run(
      'cmake',
      ['--build', p.dirname(installedDirectory), '--target', 'install'],
      app,
      environment: {'DESTDIR': staging.path},
    );
    directory = p.join(
      staging.path,
      p.relative(installedDirectory, from: p.rootPrefix(installedDirectory)),
    );
  }
  final name = Platform.isWindows ? 'chromatic-backup.exe' : 'chromatic-backup';
  final libexec = await Directory(
    p.join(directory, 'libexec'),
  ).create(recursive: true);
  final binary = await File(
    p.join(workspace, 'target', 'release', name),
  ).copy(p.join(libexec.path, name));
  if (!Platform.isWindows) await run('chmod', ['755', binary.path], app);
  if (Platform.isLinux || Platform.isWindows) {
    await run('dart', [
      'compile',
      'exe',
      'tool/app_update_helper.dart',
      '-o',
      p.join(
        libexec.path,
        Platform.isWindows ? 'chromagician-update.exe' : 'chromagician-update',
      ),
    ], app);
  }
  final packagedCatalog = Directory(p.join(directory, 'catalog'));
  if (packagedCatalog.existsSync()) {
    await packagedCatalog.delete(recursive: true);
  }
  if (catalogDirectory != null) {
    final source = Directory(catalogDirectory).absolute;
    await for (final entry in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final destination = p.join(
        packagedCatalog.path,
        p.relative(entry.path, from: source.path),
      );
      if (entry is File) {
        await File(destination).parent.create(recursive: true);
        await entry.copy(destination);
      }
    }
  }
  final packagedFirmware = Directory(p.join(directory, 'firmware'));
  if (packagedFirmware.existsSync()) {
    await packagedFirmware.delete(recursive: true);
  }
  if (firmwareDirectory != null) {
    await packageFirmwareTools(Directory(firmwareDirectory), packagedFirmware);
  }
  await removeRetiredBundleFiles(Directory(directory));
  if (Platform.isLinux) {
    await publishBundle(Directory(directory), Directory(installedDirectory));
  }
  await settings.parent.create(recursive: true);
  await settings.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({'catalog_directory': catalogDirectory == null ? null : Directory(catalogDirectory).absolute.path, 'catalog_url': catalogUrl, 'firmware_directory': firmwareDirectory == null ? null : Directory(firmwareDirectory).absolute.path})}\n',
  );
  stdout.writeln('Updated application: $installedDirectory');
}

Future<void> packageFirmwareTools(
  Directory source,
  Directory destination,
) async {
  final config =
      jsonDecode(
            await File(p.join(source.path, 'manifest.json')).readAsString(),
          )
          as Map<String, dynamic>;
  await destination.create(recursive: true);
  if (config['portable_tools'] == true) {
    for (final folder in ['tools', 'licenses']) {
      final sourceFolder = Directory(p.join(source.path, folder));
      await for (final entry in sourceFolder.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is Link) {
          throw const FormatException('Packaged tools cannot contain links.');
        }
        if (entry is! File) continue;
        final target = File(
          p.join(destination.path, p.relative(entry.path, from: source.path)),
        );
        await target.parent.create(recursive: true);
        await entry.copy(target.path);
      }
    }
  }
  await File(p.join(destination.path, 'manifest.json')).writeAsString(
    jsonEncode({
      'schema_version': 1,
      'tools': config['tools'],
      if (config['portable_tools'] == true) ...{
        'portable_tools': true,
        'versions': config['versions'],
        'libraries': config['libraries'],
        if (config['pe_imports'] != null) 'pe_imports': config['pe_imports'],
      },
    }),
  );
}

Future<void> removeBundledFirmwareImages(Directory bundle) async {
  final root = Directory(p.join(bundle.path, 'firmware')).absolute;
  final manifest = File(p.join(root.path, 'manifest.json'));
  if (!await manifest.exists()) return;
  final config =
      jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
  final releases = config['releases'];
  if (releases is! List) return;
  final images = <File>[];
  for (final release in releases) {
    for (final component in ['mcu', 'fpga']) {
      final relative = (release as Map)[component]['file'] as String;
      final path = p.normalize(p.join(root.path, relative));
      if (p.isAbsolute(relative) || !p.isWithin(root.path, path)) {
        throw const FormatException('Invalid bundled firmware path.');
      }
      images.add(File(path));
    }
  }
  for (final file in images) {
    if (await file.exists()) await file.delete();
  }
  final temporary = File('${manifest.path}.incoming');
  await temporary.writeAsString(
    jsonEncode({'schema_version': 1, 'tools': config['tools']}),
    flush: true,
  );
  await temporary.rename(manifest.path);
}

Future<void> removeRetiredBundleFiles(Directory bundle) async {
  for (final name in [
    'setup-usb.sh',
    '70-chromagician.rules',
    'LINUX-SETUP.md',
    'WINDOWS-SETUP.md',
  ]) {
    final retired = File(p.join(bundle.path, name));
    if (await retired.exists()) await retired.delete();
  }
}

Future<void> publishBundle(Directory source, Directory destination) async {
  await removeBundledFirmwareImages(destination);
  await removeRetiredBundleFiles(destination);
  await for (final entry in source.list(recursive: true, followLinks: false)) {
    final target = p.join(
      destination.path,
      p.relative(entry.path, from: source.path),
    );
    if (entry is Directory) {
      await Directory(target).create(recursive: true);
      continue;
    }
    await File(target).parent.create(recursive: true);
    final temporary = '$target.incoming';
    if (entry is File) {
      final copy = await entry.copy(temporary);
      final mode = (await entry.stat()).mode & 0x1ff;
      if (((await copy.stat()).mode & 0x1ff) != mode) {
        final result = await Process.run('chmod', [
          mode.toRadixString(8),
          temporary,
        ]);
        if (result.exitCode != 0) {
          throw FileSystemException(
            'Could not preserve file permissions',
            target,
          );
        }
      }
      await copy.rename(target);
    } else if (entry is Link) {
      final link = Link(temporary);
      if (await FileSystemEntity.type(temporary, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await link.delete();
      }
      await link.create(await entry.target());
      await link.rename(target);
    }
  }
}
