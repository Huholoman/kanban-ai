import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

/// Bodies smaller than this are sent as they are: compressing them saves
/// less than it costs.
const int minimumCompressedSize = 1024;

/// The content codings (`gzip`, `br`, …) that [header] (`Accept-Encoding`)
/// accepts, lower case; `*` stands for any other one. Codings with `q=0` are
/// left out.
Set<String> acceptedEncodings(String? header) {
  final accepted = <String>{};
  if (header == null) return accepted;
  for (final part in header.split(',')) {
    final [coding, ...parameters] = part.split(';');
    final name = coding.trim().toLowerCase();
    if (name.isEmpty) continue;
    var quality = 1.0;
    for (final parameter in parameters) {
      final [key, ...value] = parameter.split('=');
      if (key.trim().toLowerCase() == 'q') quality = double.tryParse(value.join('=').trim()) ?? 0;
    }
    if (quality > 0) accepted.add(name);
  }
  return accepted;
}

/// Whether a client sending [accepted] takes [coding].
bool acceptsEncoding(Set<String> accepted, String coding) => accepted.contains(coding) || accepted.contains('*');

/// Whether a body of [mimeType] gets smaller when compressed (text, JSON,
/// JavaScript, SVG, …; not images or archives).
bool isCompressible(String? mimeType) {
  if (mimeType == null) return false;
  final type = mimeType.toLowerCase();
  return type.startsWith('text/') ||
      type.contains('json') ||
      type.contains('javascript') ||
      type.contains('xml') ||
      type == 'application/wasm' ||
      type.startsWith('font/') && !type.contains('woff');
}

/// Compresses responses with gzip when the client accepts it
/// (`Accept-Encoding`), for compressible bodies of a known length of at least
/// [minimumCompressedSize] bytes. Responses that are already encoded, empty,
/// partial or WebSocket upgrades pass unchanged. Compressible responses get
/// `Vary: Accept-Encoding` either way, and a compressed one an ETag of its
/// own (`"…-gzip"`).
Middleware compressResponses({int level = 6}) {
  final codec = GZipCodec(level: level);
  return (inner) => (request) async {
    final response = await inner(request);
    if (request.method == 'HEAD' || request.headers.containsKey('upgrade')) return response;
    if (response.statusCode < 200 || response.statusCode == 204 || response.statusCode == 206) return response;
    if (response.statusCode == 304 || response.headers.containsKey('content-encoding')) return response;
    if (!isCompressible(response.mimeType)) return response;
    final varied = response.change(headers: {'vary': addVary(response.headers['vary'])});
    final length = response.contentLength;
    if (length == null || length < minimumCompressedSize) return varied;
    if (!acceptsEncoding(acceptedEncodings(request.headers['accept-encoding']), 'gzip')) return varied;

    final body = BytesBuilder(copy: false);
    await response.read().forEach(body.add);
    final compressed = codec.encode(body.takeBytes());
    final tag = response.headers['etag'];
    return Response(
      response.statusCode,
      body: compressed,
      headers: {
        ...response.headersAll,
        'content-length': '${compressed.length}',
        'content-encoding': 'gzip',
        'vary': addVary(response.headers['vary']),
        if (tag != null) 'etag': encodedTag(tag, 'gzip'),
      },
      context: response.context,
    );
  };
}

/// [vary] with `Accept-Encoding` added (once).
String addVary(String? vary) {
  if (vary == null || vary.trim().isEmpty) return 'Accept-Encoding';
  final fields = vary.split(',').map((field) => field.trim().toLowerCase());
  if (fields.contains('accept-encoding') || fields.contains('*')) return vary;
  return '$vary, Accept-Encoding';
}

/// The ETag of the [coding]-encoded representation of a resource tagged
/// [tag]: each representation needs its own strong validator.
String encodedTag(String tag, String coding) {
  final weak = tag.startsWith('W/');
  final opaque = weak ? tag.substring(2) : tag;
  final inner = opaque.length >= 2 && opaque.startsWith('"') && opaque.endsWith('"')
      ? opaque.substring(1, opaque.length - 1)
      : opaque;
  return '${weak ? 'W/' : ''}"$inner-$coding"';
}
