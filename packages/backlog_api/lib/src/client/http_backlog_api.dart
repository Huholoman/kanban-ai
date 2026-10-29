import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../model/item_dto.dart';
import '../model/json.dart';
import '../model/misc_dto.dart';
import '../model/requests.dart';
import '../model/view_dto.dart';
import '../model/workflow_dto.dart';
import 'backlog_api.dart';

typedef SocketConnector = WebSocketChannel Function(Uri uri);

/// [BacklogApi] over HTTP and a WebSocket for change events.
final class HttpBacklogApi implements BacklogApi {
  HttpBacklogApi(
    this.baseUri, {
    this.token,
    http.Client? client,
    SocketConnector? connectSocket,
    this.reconnectDelay = const Duration(seconds: 2),
  }) : _client = client ?? http.Client(),
       _connectSocket = connectSocket ?? WebSocketChannel.connect;

  /// Server address, e.g. `http://192.168.1.10:8640`.
  final Uri baseUri;
  final String? token;
  final Duration reconnectDelay;
  final http.Client _client;
  final SocketConnector _connectSocket;

  @override
  Future<WorkflowDto> workflow() async => WorkflowDto.fromJson(asJson(await _get(ApiPaths.workflow)));

  @override
  Future<List<ItemDto>> items({bool includeDone = false}) async {
    final json = await _get(ApiPaths.items, query: {if (includeDone) 'all': 'true'});
    return _list(json).map(ItemDto.fromJson).toList();
  }

  @override
  Future<ItemDetailDto> item(String reference) async =>
      ItemDetailDto.fromJson(asJson(await _get(ApiPaths.item(reference))));

  @override
  Future<ItemDetailDto> createItem(NewItemRequest request) async =>
      ItemDetailDto.fromJson(asJson(await _send('POST', ApiPaths.items, request.toJson())));

  @override
  Future<ItemDetailDto> updateItem(String reference, ItemUpdateRequest request) async =>
      ItemDetailDto.fromJson(asJson(await _send('PATCH', ApiPaths.item(reference), request.toJson())));

  @override
  Future<ItemDetailDto> claim(String reference, ClaimRequest request) => _action(reference, 'claim', request);

  @override
  Future<ItemDetailDto> release(String reference, ClaimRequest request) => _action(reference, 'release', request);

  @override
  Future<ItemDetailDto> complete(String reference, ClaimRequest request) => _action(reference, 'done', request);

  @override
  Future<List<ViewSummaryDto>> views() async => _list(await _get(ApiPaths.views)).map(ViewSummaryDto.fromJson).toList();

  @override
  Future<ViewResultDto> view(String id) async => ViewResultDto.fromJson(asJson(await _get(ApiPaths.view(id))));

  @override
  Future<ViewSummaryDto> updateView(String id, ViewUpdateRequest request) async =>
      ViewSummaryDto.fromJson(asJson(await _send('PATCH', ApiPaths.view(id), request.toJson())));

  @override
  Future<List<LintIssueDto>> lint() async => _list(await _get(ApiPaths.lint)).map(LintIssueDto.fromJson).toList();

  @override
  Stream<BacklogChangeEvent> changes() {
    late final StreamController<BacklogChangeEvent> controller;
    WebSocketChannel? channel;
    var active = true;

    Future<void> run() async {
      while (active) {
        try {
          final socket = channel = _connectSocket(_socketUri());
          await socket.ready;
          await for (final message in socket.stream) {
            final json = asJson(jsonDecode(message as String));
            if (json['type'] == 'changed') controller.add(BacklogChangeEvent.fromJson(json));
          }
        } catch (_) {
          // Server restarting or unreachable: retry below.
        }
        if (active) await Future<void>.delayed(reconnectDelay);
      }
    }

    controller = StreamController<BacklogChangeEvent>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        active = false;
        await channel?.sink.close();
      },
    );
    return controller.stream;
  }

  Uri _socketUri() {
    final uri = _uri(ApiPaths.events, {'token': ?token});
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  Uri _uri(String path, [Map<String, String> query = const {}]) =>
      baseUri.replace(path: path, queryParameters: query.isEmpty ? null : query);

  Map<String, String> get _headers => {
    'accept': 'application/json',
    if (token != null) 'authorization': 'Bearer $token',
  };

  Future<ItemDetailDto> _action(String reference, String action, ClaimRequest request) async =>
      ItemDetailDto.fromJson(asJson(await _send('POST', ApiPaths.itemAction(reference, action), request.toJson())));

  Future<Object?> _get(String path, {Map<String, String> query = const {}}) =>
      _handle(() => _client.get(_uri(path, query), headers: _headers));

  Future<Object?> _send(String method, String path, Json body) => _handle(() {
    final request = http.Request(method, _uri(path))
      ..headers.addAll({..._headers, 'content-type': 'application/json'})
      ..body = jsonEncode(body);
    return _client.send(request).then(http.Response.fromStream);
  });

  Future<Object?> _handle(Future<http.Response> Function() call) async {
    final http.Response response;
    try {
      response = await call();
    } on http.ClientException catch (error) {
      throw BacklogApiException(0, 'network', 'Server unreachable: ${error.message}');
    }
    final text = utf8.decode(response.bodyBytes);
    final Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      throw BacklogApiException(response.statusCode, 'internal', 'Unexpected response: $text');
    }
    if (response.statusCode >= 400) {
      if (json is Map<String, Object?> && json['error'] is Map) {
        throw BacklogApiException.fromJson(response.statusCode, json);
      }
      throw BacklogApiException(response.statusCode, 'internal', 'HTTP ${response.statusCode}: $text');
    }
    return json;
  }

  static List<Json> _list(Object? json) =>
      json is List<Object?> ? json.map(asJson).toList() : throw MalformedPayloadException('Expected a list.');

  void close() => _client.close();
}
