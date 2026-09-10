import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef Json = Map<String, dynamic>;

String? cartridgeKey(Json header) {
  if (header['global_checksum'] == null ||
      header['header_checksum'] == null ||
      header['rom_version'] == null) {
    return null;
  }
  return [
    header['color'] == true ? 'gbc' : 'gb',
    (header['title'] as String).trim(),
    header['rom_size'],
    header['global_checksum'],
    header['header_checksum'],
    header['rom_version'],
  ].join('|');
}

abstract class CartCatalog {
  Future<GameMetadata?> lookup(Json header, {String? crc32});
  void dispose() {}
}

class GameMetadata {
  const GameMetadata(
    this.record, {
    this.coverBytes,
    this.region,
    this.system,
    this.releaseName,
  });
  final Json record;
  final Uint8List? coverBytes;
  final String? region;
  final String? system;

  final String? releaseName;
  String get title => record['title'] as String;
  String? get summary => record['summary'] as String?;
  List<String> get developers => List<String>.from(record['developers'] ?? []);
  List<String> get publishers => List<String>.from(record['publishers'] ?? []);
  List<String> get genres => List<String>.from(record['genres'] ?? []);
  double? get stars {
    final rating = record['rating'];
    if (rating is! num || !rating.isFinite || rating < 0 || rating > 100) {
      return null;
    }
    return rating / 20;
  }

  String? get releaseDate {
    final releases = (record['releases'] as List? ?? [])
        .cast<Json>()
        .where((row) => row['system'] == system)
        .toList();
    final wanted = switch (region) {
      'NTSC-U' => 'north_america',
      'NTSC-J' => 'japan',
      'PAL' => 'europe',
      _ => null,
    };
    final regional = releases
        .where((row) => row['release_region']?['region'] == wanted)
        .toList();
    if (regional.isNotEmpty) return regional.first['human'] as String?;
    final years = releases.map((row) => row['y']).whereType<int>().toSet();
    return years.length == 1 ? years.single.toString() : null;
  }
}

class GameCatalog extends CartCatalog {
  GameCatalog({required this.source, required this.cache});
  final Uri source;
  final Directory cache;
  Future<Json>? _manifest;
  Future<Json>? _identity;
  final Map<String, Future<Uint8List>> _pending = {};
  bool _disposed = false;
  final Set<HttpClient> _clients = {};

  static Future<GameCatalog?> configured() async {
    final directory = Platform.environment['CHROMATIC_CATALOG_DIR'];
    final url =
        Platform.environment['CHROMATIC_CATALOG_URL'] ??
        const String.fromEnvironment('CHROMATIC_CATALOG_URL');
    Uri? source;
    if (directory != null && directory.isNotEmpty) {
      source = Directory(directory).absolute.uri;
    } else if (url.isNotEmpty) {
      source = Uri.parse(url.endsWith('/') ? url : '$url/');
    } else {
      final packaged = Directory(
        p.join(p.dirname(Platform.resolvedExecutable), 'catalog'),
      );
      source = await packaged.exists()
          ? packaged.uri
          : Uri.parse('https://chromagic.org/');
    }
    if (source.scheme != 'file' &&
        source.scheme != 'https' &&
        !(source.scheme == 'http' &&
            ['localhost', '127.0.0.1', '::1'].contains(source.host))) {
      throw const FormatException('Catalog URL must use HTTPS.');
    }
    final support = await getApplicationSupportDirectory();
    return GameCatalog(
      source: source,
      cache: Directory(
        p.join(
          support.path,
          'catalog',
          sha256.convert(utf8.encode(source.toString())).toString(),
        ),
      ),
    );
  }

  Uri _resolve(String path) {
    final relative = Uri.parse(path);
    if (relative.hasScheme ||
        relative.hasAuthority ||
        relative.hasQuery ||
        relative.hasFragment ||
        relative.path.startsWith('/') ||
        relative.pathSegments.any((s) => s == '..' || s.contains('\\'))) {
      throw const FormatException(
        'Catalog paths must stay inside the configured source.',
      );
    }
    final resolved = source.resolveUri(relative);
    if (source.scheme != 'file' && resolved.origin != source.origin) {
      throw const FormatException('External catalog asset rejected.');
    }
    return resolved;
  }

  Future<Uint8List> _read(String path) async {
    if (_disposed) throw const FileSystemException('Catalog closed');
    final uri = _resolve(path);
    if (uri.scheme == 'file') {
      final file = File.fromUri(uri);
      final real = await file.resolveSymbolicLinks();
      final root = await Directory.fromUri(source).resolveSymbolicLinks();
      if (!p.isWithin(root, real)) {
        throw const FormatException('Catalog file outside source.');
      }
      if (await file.length() > 12 * 1024 * 1024) {
        throw const FormatException('Catalog file too large.');
      }
      return file.readAsBytes();
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    _clients.add(client);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Catalog request failed (${response.statusCode}).');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        bytes.add(chunk);
        if (bytes.length > 12 * 1024 * 1024) {
          throw const FormatException('Catalog file too large.');
        }
      }
      return bytes.takeBytes();
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<void> _save(File file, Uint8List data) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data, flush: true);
    } on FileSystemException {
    }
  }

  Future<Json> _loadManifest() async {
    final file = File(p.join(cache.path, 'manifest.json'));
    Json parse(Uint8List bytes) {
      final result = jsonDecode(utf8.decode(bytes)) as Json;
      if (result['schema_version'] != 1 ||
          result['asset_base'] != 'site-root') {
        throw const FormatException('Unsupported catalog format.');
      }
      return result;
    }

    try {
      final bytes = await _read('catalog/v1/manifest.json');
      final manifest = parse(bytes);
      await _save(file, bytes);
      return manifest;
    } on Object {
      return parse(await file.readAsBytes());
    }
  }

  Future<Uint8List> _asset(Json descriptor) {
    final path = descriptor['path'] as String;
    _resolve(path);
    return _pending
        .putIfAbsent(path, () async {
          final hash = descriptor['sha256'] as String;
          if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
            throw const FormatException('Invalid asset hash.');
          }
          final file = File(p.join(cache.path, hash));
          bool valid(Uint8List data) =>
              data.length == descriptor['bytes'] &&
              sha256.convert(data).toString() == hash;
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            if (valid(bytes)) return bytes;
          }
          final bytes = await _read(path);
          if (!valid(bytes)) {
            throw const FormatException('Catalog asset checksum mismatch.');
          }
          if (source.scheme != 'file') await _save(file, bytes);
          return bytes;
        })
        .whenComplete(() => _pending.remove(path));
  }

  Future<Json> _getManifest() =>
      _manifest ??= _loadManifest().catchError((Object error) {
        _manifest = null;
        throw error;
      });

  Future<Json> _getIdentity() => _identity ??=
      (() async {
        final manifest = await _getManifest();
        if (manifest['identity'] == null) return <String, dynamic>{};
        return jsonDecode(
              utf8.decode(await _asset(manifest['identity'] as Json)),
            )
            as Json;
      })().catchError((Object error) {
        _identity = null;
        throw error;
      });

  @override
  Future<GameMetadata?> lookup(Json header, {String? crc32}) async {
    final identity = await _getIdentity();
    final system = header['color'] == true ? 'gbc' : 'gb';
    List<Json> candidatesFor(String indexName, String? key) {
      final rows = (identity[indexName] as Map?)?[key] as List? ?? [];
      return rows
          .cast<Json>()
          .where(
            (entry) =>
                (entry['system'] == null || entry['system'] == system) &&
                (entry['rom_size'] == null ||
                    entry['rom_size'] == header['rom_size']),
          )
          .toList();
    }

    var candidates = crc32 == null
        ? <Json>[]
        : candidatesFor(
            'crc32',
            '${header['rom_size']}:${crc32.toLowerCase()}',
          );
    if (candidates.isEmpty) {
      candidates = candidatesFor(
        'header_sha1',
        header['header_sha1'] as String?,
      );
    }
    if (candidates.isEmpty) {
      candidates = candidatesFor('headers', cartridgeKey(header));
    }
    var exactRelease = true;
    if (candidates.isEmpty) {
      exactRelease = false;
      candidates = candidatesFor(
        'header_families',
        [
          system,
          (header['title'] as String).trim(),
          header['rom_size'],
        ].join('|'),
      );
    }
    if (candidates.isEmpty ||
        candidates.any((row) => row['id'] == null) ||
        candidates.map((row) => row['id']).toSet().length != 1) {
      return null;
    }
    final regions = candidates.map((row) => row['region']).toSet();
    final releaseNames = candidates
        .map((row) => row['release_name'])
        .whereType<String>()
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    return _game(
      candidates.first,
      header,
      region: regions.length == 1 ? regions.single as String? : null,
      releaseName: exactRelease && releaseNames.length == 1
          ? releaseNames.single
          : null,
    );
  }

  Future<GameMetadata> _game(
    Json entry,
    Json header, {
    String? region,
    String? releaseName,
  }) async {
    final record =
        jsonDecode(utf8.decode(await _asset(entry['record'] as Json))) as Json;
    Json? cover = record['cover'] as Json?;
    final regionName = switch (region) {
      'NTSC-J' => 'Japan',
      'PAL' => 'Europe',
      _ => null,
    };
    for (final localization in record['localizations'] as List? ?? []) {
      if (regionName != null &&
          localization['region']?['name'] == regionName &&
          localization['cover'] != null) {
        cover = localization['cover'] as Json;
      }
    }
    Uint8List? bytes;
    if (cover != null) {
      try {
        bytes = await _asset(cover);
      } on Object {
      }
    }
    return GameMetadata(
      record,
      coverBytes: bytes,
      releaseName: releaseName,
      region: region,
      system:
          entry['system'] as String? ??
          (header['color'] == true ? 'gbc' : 'gb'),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }
}
