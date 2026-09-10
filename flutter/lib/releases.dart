import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

const appRepository = 'cursedtoast2/ChroMagician';
const firmwareRepository = 'cursedtoast2/ChroMagic';
const stockMcuRepository = 'ModRetro/oss-chromatic-console-mcu';
const stockFpgaRepository = 'ModRetro/oss-chromatic-console-fpga';

Version? releaseVersion(String text) {
  final match = RegExp(
    r'(?:^|\s|v)(\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.-]+)?)(?=$|\s|\+)',
  ).firstMatch(text);
  if (match == null) return null;
  var value = match[1]!;
  if (value.split('-').first.split('.').length == 2) value = '$value.0';
  try {
    return Version.parse(value);
  } on FormatException {
    return null;
  }
}

class ReleaseFailure implements Exception {
  const ReleaseFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ReleaseAsset {
  ReleaseAsset(Map<String, dynamic> json)
    : name = json['name'] as String,
      id = json['id'] as int,
      size = json['size'] as int,
      digest = (json['digest'] as String?)?.replaceFirst('sha256:', '');
  final String name;
  final int id, size;
  final String? digest;
}

class GitHubRelease {
  GitHubRelease(this.repository, this.json)
    : tag = json['tag_name'] as String,
      version = releaseVersion(json['tag_name'] as String),
      assets = (json['assets'] as List)
          .map((e) => ReleaseAsset(Map<String, dynamic>.from(e as Map)))
          .toList();
  final String repository, tag;
  final Version? version;
  final Map<String, dynamic> json;
  final List<ReleaseAsset> assets;
  Uri get page => Uri.https('github.com', '/$repository/releases/tag/$tag');
  ReleaseAsset asset(String name) {
    final matches = assets.where((a) => a.name == name).toList();
    if (matches.length != 1) {
      throw ReleaseFailure('The release is missing $name.');
    }
    return matches.single;
  }
}

abstract class ReleaseTransport {
  Future<List<int>> get(
    Uri uri, {
    bool binary = false,
    int limit = 2 * 1024 * 1024,
  });
}

class GitHubTransport implements ReleaseTransport {
  Future<String?>? _token;
  Future<String?> _localToken() async {
    final environment = Platform.environment['CHROMAGIC_GITHUB_TOKEN'];
    if (environment != null && environment.isNotEmpty) return environment;
    try {
      final home = Platform.environment['HOME'];
      final localGh = home == null
          ? null
          : File(p.join(home, '.local', 'bin', 'gh'));
      final command = localGh != null && await localGh.exists()
          ? localGh.path
          : 'gh';
      final process = await Process.start(command, [
        'auth',
        'token',
        '--hostname',
        'github.com',
      ]);
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.drain<void>();
      final timer = Timer(const Duration(seconds: 3), () => process.kill());
      try {
        final code = await process.exitCode;
        final token = (await output).trim();
        await errors;
        return code == 0 && token.isNotEmpty ? token : null;
      } finally {
        timer.cancel();
      }
    } on Object {
      return null;
    }
  }

  @override
  Future<List<int>> get(
    Uri uri, {
    bool binary = false,
    int limit = 2 * 1024 * 1024,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final token = await (_token ??= _localToken());
    try {
      return await (() async {
        for (var redirects = 0; redirects < 5; redirects++) {
          if (uri.scheme != 'https' ||
              !(uri.host == 'api.github.com' ||
                  uri.host == 'github.com' ||
                  uri.host.endsWith('.githubusercontent.com'))) {
            throw const ReleaseFailure(
              'The release download address is invalid.',
            );
          }
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          request.headers.set(HttpHeaders.userAgentHeader, 'ChroMagician');
          request.headers.set(
            HttpHeaders.acceptHeader,
            binary ? 'application/octet-stream' : 'application/vnd.github+json',
          );
          if (uri.host == 'api.github.com') {
            request.headers.set('X-GitHub-Api-Version', '2022-11-28');
            if (token != null) {
              request.headers.set(
                HttpHeaders.authorizationHeader,
                'Bearer $token',
              );
            }
          }
          final response = await request.close();
          if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location == null) {
              throw const ReleaseFailure(
                'The release download address is missing.',
              );
            }
            uri = uri.resolve(location);
            await response.drain<void>();
            continue;
          }
          if (response.statusCode != 200) {
            throw ReleaseFailure(
              response.statusCode == 404
                  ? 'No accessible release is available yet.'
                  : 'Could not check GitHub releases (${response.statusCode}).',
            );
          }
          final bytes = <int>[];
          await for (final chunk in response) {
            bytes.addAll(chunk);
            if (bytes.length > limit) {
              throw const ReleaseFailure('The release download is too large.');
            }
          }
          return bytes;
        }
        throw const ReleaseFailure(
          'The release download redirected too many times.',
        );
      })().timeout(
        binary ? const Duration(minutes: 2) : const Duration(seconds: 15),
      );
    } on TimeoutException {
      throw const ReleaseFailure('The release server did not respond.');
    } on SocketException {
      throw const ReleaseFailure('Could not connect to the release server.');
    } finally {
      client.close(force: true);
    }
  }
}

class ReleaseClient {
  ReleaseClient(this.cache, {ReleaseTransport? transport})
    : transport = transport ?? GitHubTransport();
  final Directory cache;
  final ReleaseTransport transport;

  Future<GitHubRelease?> latest(
    String repository, {
    bool prereleases = true,
    bool allowCached = false,
  }) async {
    final record = File(
      p.join(
        cache.path,
        '${repository.replaceAll('/', '-')}-${prereleases ? 'all' : 'stable'}.json',
      ),
    );
    try {
      final bytes = await transport.get(
        Uri.https('api.github.com', '/repos/$repository/releases', {
          'per_page': '100',
        }),
      );
      final values = jsonDecode(utf8.decode(bytes)) as List;
      final releases =
          values
              .cast<Map<String, dynamic>>()
              .where(
                (j) =>
                    j['draft'] != true &&
                    (prereleases || j['prerelease'] != true),
              )
              .map((j) => GitHubRelease(repository, j))
              .where((r) => r.version != null)
              .toList()
            ..sort((a, b) => b.version!.compareTo(a.version!));
      final latest = releases.firstOrNull;
      if (latest != null) {
        await record.parent.create(recursive: true);
        await _atomicWrite(record, utf8.encode(jsonEncode(latest.json)));
      } else if (await record.exists()) {
        await record.delete();
      }
      return latest;
    } on Object {
      if (allowCached && await record.exists()) {
        try {
          return GitHubRelease(
            repository,
            jsonDecode(await record.readAsString()) as Map<String, dynamic>,
          );
        } on Object {
        }
      }
      rethrow;
    }
  }

  Future<File> download(
    GitHubRelease release,
    ReleaseAsset asset, {
    String? expectedHash,
    int maxBytes = 16 * 1024 * 1024,
  }) async {
    final hash = expectedHash ?? asset.digest;
    if (hash == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        asset.size <= 0 ||
        asset.size > maxBytes) {
      throw const ReleaseFailure(
        'The release is missing a valid checksum or size.',
      );
    }
    if (asset.digest != null && asset.digest != hash) {
      throw const ReleaseFailure('The release checksums disagree.');
    }
    final target = File(p.join(cache.path, 'assets', hash));
    if (await target.exists() &&
        await target.length() == asset.size &&
        (await sha256.bind(target.openRead()).first).toString() == hash) {
      return target;
    }
    final bytes = await transport.get(
      Uri.https(
        'api.github.com',
        '/repos/${release.repository}/releases/assets/${asset.id}',
      ),
      binary: true,
      limit: maxBytes,
    );
    if (bytes.length != asset.size ||
        sha256.convert(bytes).toString() != hash) {
      throw const ReleaseFailure('The download did not pass verification.');
    }
    await target.parent.create(recursive: true);
    await _atomicWrite(target, bytes);
    return target;
  }
}

Future<void> _atomicWrite(File target, List<int> bytes) async {
  final staging = await target.parent.createTemp('.download-');
  final temporary = File(p.join(staging.path, 'payload'));
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    if (Platform.isWindows && await target.exists()) await target.delete();
    await temporary.rename(target.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
    await staging.delete();
  }
}
