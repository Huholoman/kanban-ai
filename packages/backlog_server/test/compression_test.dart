import 'dart:convert';
import 'dart:io';

import 'package:backlog_server/src/http/compression.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('acceptedEncodings', () {
    test('reads codings, ignores q=0 and case', () {
      expect(acceptedEncodings('gzip, deflate, br, zstd'), {'gzip', 'deflate', 'br', 'zstd'});
      expect(acceptedEncodings('GZip;q=0.5, br;q=0, identity'), {'gzip', 'identity'});
      expect(acceptedEncodings(null), isEmpty);
      expect(acceptedEncodings(''), isEmpty);
      expect(acceptsEncoding(acceptedEncodings('*'), 'br'), isTrue);
      expect(acceptsEncoding(acceptedEncodings('gzip'), 'br'), isFalse);
    });
  });

  test('addVary and encodedTag', () {
    expect(addVary(null), 'Accept-Encoding');
    expect(addVary('Origin'), 'Origin, Accept-Encoding');
    expect(addVary('origin, accept-encoding'), 'origin, accept-encoding');
    expect(encodedTag('"abc"', 'br'), '"abc-br"');
    expect(encodedTag('W/"abc"', 'gzip'), 'W/"abc-gzip"');
  });

  group('compressResponses', () {
    final big = jsonEncode({'items': List.filled(200, 'some repeated text')});
    final small = jsonEncode({'ok': true});
    const json = {'content-type': 'application/json; charset=utf-8'};

    Future<Response> serve(Response response, {String? accept = 'gzip, deflate, br', String method = 'GET'}) async =>
        compressResponses()((_) => response)(
          Request(method, Uri.parse('http://localhost/api/items'), headers: {'accept-encoding': ?accept}),
        );

    test('gzips a large JSON body for clients that accept it', () async {
      final response = await serve(Response.ok(big, headers: {...json, 'etag': '"t1"'}));
      expect(response.headers['content-encoding'], 'gzip');
      expect(response.headers['vary'], 'Accept-Encoding');
      expect(response.headers['etag'], '"t1-gzip"');
      final bytes = await response.read().expand((chunk) => chunk).toList();
      expect(int.parse(response.headers['content-length']!), bytes.length);
      expect(bytes.length, lessThan(big.length ~/ 5));
      expect(utf8.decode(gzip.decode(bytes)), big);
    });

    test('leaves small bodies, other clients and non-text alone', () async {
      final tiny = await serve(Response.ok(small, headers: json));
      expect(tiny.headers.containsKey('content-encoding'), isFalse);
      expect(await tiny.readAsString(), small);

      final plain = await serve(Response.ok(big, headers: json), accept: null);
      expect(plain.headers.containsKey('content-encoding'), isFalse);
      expect(plain.headers['vary'], 'Accept-Encoding');
      expect(await plain.readAsString(), big);

      final png = await serve(Response.ok(utf8.encode(big), headers: {'content-type': 'image/png'}));
      expect(png.headers.containsKey('content-encoding'), isFalse);
      expect(png.headers.containsKey('vary'), isFalse);

      final head = await serve(Response.ok(big, headers: json), method: 'HEAD');
      expect(head.headers.containsKey('content-encoding'), isFalse);
    });

    test('keeps an encoding set by the handler', () async {
      final encoded = gzip.encode(utf8.encode(big));
      final response = await serve(Response.ok(encoded, headers: {...json, 'content-encoding': 'gzip'}));
      expect(await response.read().expand((chunk) => chunk).toList(), encoded);
    });
  });
}
