import 'dart:convert';
import 'dart:math';

import 'package:backlog_api/backlog_api.dart';
import 'package:shelf/shelf.dart';

/// A random URL-safe token for [requireToken]: 22 characters, ~130 bits.
String generateToken({Random? random}) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final source = random ?? Random.secure();
  return String.fromCharCodes([for (var i = 0; i < 22; i++) alphabet.codeUnitAt(source.nextInt(alphabet.length))]);
}

/// Requires `Authorization: Bearer <token>` (or `?token=` for WebSockets,
/// which browsers open without custom headers) on `/api/` requests.
Middleware requireToken(String token) =>
    (inner) => (request) {
      if (!request.url.path.startsWith('api/') || request.url.path == 'api/health') return inner(request);
      final header = request.headers['authorization'];
      final given = header != null && header.startsWith('Bearer ')
          ? header.substring('Bearer '.length)
          : request.url.queryParameters['token'];
      if (given == token) return inner(request);
      return Response(
        401,
        body: jsonEncode(const BacklogApiException(401, 'unauthorized', 'Missing or wrong token.').toJson()),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    };

/// Lets the app run from another origin (e.g. `flutter run -d web-server`).
Middleware allowCrossOrigin() =>
    (inner) => (request) async {
      const headers = {
        'access-control-allow-origin': '*',
        'access-control-allow-methods': 'GET, POST, PATCH, OPTIONS',
        'access-control-allow-headers': 'authorization, content-type, accept',
      };
      if (request.method == 'OPTIONS') return Response.ok(null, headers: headers);
      final response = await inner(request);
      return response.change(headers: headers);
    };
