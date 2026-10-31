import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_static/shelf_static.dart';

import 'compression.dart';

/// Serves the built web app so that browsers always notice a new build.
///
/// `shelf_static` validates caches by modification time only, and files in
/// the Nix store all have the same one (1970), so a browser kept e.g. an old,
/// tree-shaken icon font after an update. Here every response carries an
/// ETag derived from where the build lives and the file's size and time
/// (a new Nix build is a new store path; a local rebuild changes the times)
/// and `Cache-Control: no-cache`, so browsers revalidate and get a 304 only
/// for the very same file.
///
/// Files compressed at build time next to the originals (`main.dart.js.br`,
/// `main.dart.js.gz`; see `packages/backlog_app/tool/precompress.sh`) are
/// sent instead when the client accepts their encoding, Brotli first, with
/// `Content-Encoding`, `Vary: Accept-Encoding` and an ETag per encoding. A
/// compressed file older than its original (a stale leftover of an earlier
/// build) is ignored.
Handler webAppHandler(String webRoot) {
  final root = Directory(webRoot).resolveSymbolicLinksSync();
  final files = createStaticHandler(root, defaultDocument: 'index.html');

  return (request) async {
    final file = _fileFor(root, request.url.path);
    final type = file == null ? null : lookupMimeType(file.path);
    final compressible = isCompressible(type);
    final variant = file != null && compressible && !request.headers.containsKey('range')
        ? _compressedVariant(file, acceptedEncodings(request.headers['accept-encoding']))
        : null;
    final baseTag = file == null ? null : _etag(root, file);
    final tag = baseTag == null || variant == null ? baseTag : encodedTag(baseTag, variant.coding);
    final common = {'cache-control': 'no-cache', if (compressible) 'vary': 'Accept-Encoding'};
    if (tag != null && _matches(request.headers['if-none-match'], tag)) {
      return Response.notModified(headers: {'etag': tag, ...common});
    }
    if (variant != null) {
      return Response.ok(
        request.method == 'HEAD' ? null : variant.file.openRead(),
        headers: {
          'content-type': type!,
          'content-length': '${variant.file.lengthSync()}',
          'content-encoding': variant.coding,
          'etag': tag!,
          ...common,
        },
      );
    }
    // Without the date the static handler never answers 304 by itself.
    final response = await files(request.change(headers: {'if-modified-since': null}));
    return response.change(
      headers: {'last-modified': null, ...common, if (tag != null && response.statusCode == 200) 'etag': tag},
    );
  };
}

/// Whether `If-None-Match` [header] names [tag] (or `*`).
bool _matches(String? header, String tag) =>
    header != null && header.split(',').map((candidate) => candidate.trim()).any((c) => c == tag || c == '*');

/// The compressed copy of [file] to send to a client accepting [accepted].
({File file, String coding})? _compressedVariant(File file, Set<String> accepted) {
  final modified = file.statSync().modified;
  for (final (coding, extension) in const [('br', 'br'), ('gzip', 'gz')]) {
    if (!acceptsEncoding(accepted, coding)) continue;
    final candidate = File('${file.path}.$extension');
    final stat = candidate.statSync();
    if (stat.type == FileSystemEntityType.file && !stat.modified.isBefore(modified)) {
      return (file: candidate, coding: coding);
    }
  }
  return null;
}

/// The file the static handler serves for [path], or null.
File? _fileFor(String root, String path) {
  final candidate = p.normalize(p.join(root, path));
  if (!p.isWithin(root, candidate) && candidate != root) return null;
  if (FileSystemEntity.isDirectorySync(candidate)) {
    final index = File(p.join(candidate, 'index.html'));
    return index.existsSync() ? index : null;
  }
  final file = File(candidate);
  return file.existsSync() ? file : null;
}

String _etag(String root, File file) {
  final stat = file.statSync();
  final key = '$root|${p.relative(file.path, from: root)}|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
  // FNV-1a over 64-bit ints (they wrap on overflow): stable across runs,
  // unlike String.hashCode.
  var hash = -0x340d631b7bdddcdb; // 0xcbf29ce484222325
  for (final unit in key.codeUnits) {
    hash = (hash ^ unit) * 0x100000001b3;
  }
  return '"${hash.toUnsigned(64).toRadixString(16)}"';
}
