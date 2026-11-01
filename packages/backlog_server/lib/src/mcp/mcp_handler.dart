import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'mcp_tools.dart';

/// The Model Context Protocol over streamable HTTP at `/mcp`, stateless:
/// every `POST` carries one JSON-RPC message and a request is answered with
/// one JSON response (no sessions, no server-sent events, so `GET` is 405).
///
/// It knows `initialize` (with [McpTools.instructions]), `ping`,
/// `tools/list` and `tools/call` ([McpTools]); notifications and responses
/// of the client are accepted with 202.
final class McpHandler {
  McpHandler(this._tools, {this.version = '0.1.0'});

  final McpTools _tools;

  /// The server version told to clients in `initialize`.
  final String version;

  /// Protocol revisions this server speaks, newest first; a client asking for
  /// another one gets the newest.
  static const protocolVersions = ['2025-06-18', '2025-03-26', '2024-11-05'];

  Handler get handler => (request) async {
    if (!_sameOrigin(request)) {
      return _rpcError(null, -32600, 'Requests from another origin are refused.', status: 403);
    }
    if (request.method != 'POST') {
      return Response(405, body: 'POST JSON-RPC messages to /mcp.', headers: {'allow': 'POST'});
    }
    final Object? message;
    try {
      message = jsonDecode(await request.readAsString());
    } on FormatException catch (error) {
      return _rpcError(null, -32700, 'Parse error: ${error.message}', status: 400);
    }
    if (message is! Map<String, Object?> || message['jsonrpc'] != '2.0') {
      return _rpcError(null, -32600, 'Send one JSON-RPC 2.0 message per request.', status: 400);
    }
    final id = message['id'];
    final method = message['method'];
    // A notification or a response of the client: nothing to answer.
    if (method == null || !message.containsKey('id')) return Response(202);
    if (method is! String) return _rpcError(id, -32600, '"method" must be a string.', status: 400);
    final params = message['params'] ?? const <String, Object?>{};
    if (params is! Map<String, Object?>) return _rpcError(id, -32602, '"params" must be an object.');
    return switch (method) {
      'initialize' => _result(id, _initialize(params)),
      'ping' => _result(id, const <String, Object?>{}),
      'tools/list' => _result(id, {'tools': _tools.definitions}),
      'tools/call' => _call(id, params),
      _ => _rpcError(id, -32601, 'Method not found: $method'),
    };
  };

  Map<String, Object?> _initialize(Map<String, Object?> params) {
    final requested = params['protocolVersion'];
    return {
      'protocolVersion': protocolVersions.contains(requested) ? requested : protocolVersions.first,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {'name': 'kanban-ai', 'title': 'kanban-ai backlog', 'version': version},
      'instructions': McpTools.instructions,
    };
  }

  Future<Response> _call(Object? id, Map<String, Object?> params) async {
    final name = params['name'];
    final arguments = params['arguments'] ?? const <String, Object?>{};
    if (name is! String || !_tools.has(name)) return _rpcError(id, -32602, 'Unknown tool: $name');
    if (arguments is! Map<String, Object?>) return _rpcError(id, -32602, '"arguments" must be an object.');
    return _result(id, await _tools.call(name, arguments));
  }

  /// Browsers send `Origin`; a page of another site must not reach the
  /// backlog through the user's browser (DNS rebinding). Other clients send
  /// none.
  static bool _sameOrigin(Request request) {
    final origin = request.headers['origin'];
    if (origin == null || origin == 'null') return origin == null;
    final host = request.headers['host'];
    return host != null && Uri.tryParse(origin)?.authority == host;
  }

  static Response _result(Object? id, Object? result) => _json({'jsonrpc': '2.0', 'id': id, 'result': result});

  static Response _rpcError(Object? id, int code, String message, {int status = 200}) => _json({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  }, status: status);

  static Response _json(Object? body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'},
  );
}
