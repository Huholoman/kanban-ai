import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../model/agent_log_update_dto.dart';
import '../model/discussion_dto.dart';
import '../model/dispatch_dto.dart';
import '../model/epic_dto.dart';
import '../model/history_dto.dart';
import '../model/item_dto.dart';
import '../model/json.dart';
import '../model/misc_dto.dart';
import '../model/project_dto.dart';
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
    this.project,
    http.Client? client,
    SocketConnector? connectSocket,
    this.reconnectDelay = const Duration(seconds: 2),
  }) : _client = client ?? http.Client(),
       _connectSocket = connectSocket ?? WebSocketChannel.connect;

  /// Server address, e.g. `http://192.168.1.10:8640`.
  final Uri baseUri;
  final String? token;

  /// Project whose paths (`/api/p/<id>/…`) are used; null for the server's
  /// default project.
  final String? project;
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
  Future<ItemDetailDto> comment(String reference, CommentRequest request) async =>
      ItemDetailDto.fromJson(asJson(await _send('POST', ApiPaths.itemAction(reference, 'comments'), request.toJson())));

  @override
  Future<List<ViewSummaryDto>> views() async => _list(await _get(ApiPaths.views)).map(ViewSummaryDto.fromJson).toList();

  @override
  Future<ViewResultDto> view(String id, {String? groupBy}) async =>
      ViewResultDto.fromJson(asJson(await _get(ApiPaths.view(id), query: {'group_by': ?groupBy})));

  @override
  Future<ViewSummaryDto> updateView(String id, ViewUpdateRequest request) async =>
      ViewSummaryDto.fromJson(asJson(await _send('PATCH', ApiPaths.view(id), request.toJson())));

  @override
  Future<ViewSummaryDto> createView(NewViewRequest request) async =>
      ViewSummaryDto.fromJson(asJson(await _send('POST', ApiPaths.views, request.toJson())));

  @override
  Future<List<LintIssueDto>> lint() async => _list(await _get(ApiPaths.lint)).map(LintIssueDto.fromJson).toList();

  @override
  Future<DispatchDto> dispatch() async => DispatchDto.fromJson(asJson(await _get(ApiPaths.dispatch)));

  @override
  Future<DispatchDto> startAgent(String reference, {bool fresh = false}) async => DispatchDto.fromJson(
    asJson(await _send('POST', ApiPaths.dispatchStart, DispatchRequest(reference, fresh: fresh).toJson())),
  );

  @override
  Future<List<HistoryEntryDto>> history(String reference, {String? only}) async =>
      _list(await _get(ApiPaths.history(reference), query: {'only': ?only})).map(HistoryEntryDto.fromJson).toList();

  @override
  Future<EpicDto> epic(String reference, {String? milestone}) async =>
      EpicDto.fromJson(asJson(await _get(ApiPaths.epic(reference), query: {'milestone': ?milestone})));

  @override
  Future<DispatchDto> startEpic(String reference, {bool fresh = false, String? milestone}) async =>
      DispatchDto.fromJson(
        asJson(
          await _send(
            'POST',
            ApiPaths.dispatchEpic,
            DispatchRequest(reference, fresh: fresh, milestone: milestone).toJson(),
          ),
        ),
      );

  @override
  Future<DispatchDto> cancelQueued(String reference) async =>
      DispatchDto.fromJson(asJson(await _send('DELETE', ApiPaths.queued(reference), const {})));

  @override
  Future<DispatchDto> dismissProblems(String reference) async =>
      DispatchDto.fromJson(asJson(await _send('DELETE', ApiPaths.problems(reference), const {})));

  @override
  Future<DispatchDto> stopAgent(String reference) async =>
      DispatchDto.fromJson(asJson(await _send('POST', ApiPaths.dispatchStop, DispatchRequest(reference).toJson())));

  @override
  Future<DispatchDto> runAction(String reference, String name) async =>
      DispatchDto.fromJson(asJson(await _send('POST', ApiPaths.runAction(reference, name), const {})));

  @override
  Future<AgentLogDto> agentLog(String reference, {int lines = 100}) async =>
      AgentLogDto.fromJson(asJson(await _get(ApiPaths.agentLog(reference), query: {'lines': '$lines'})));

  @override
  Stream<BacklogChangeEvent> changes() => _socket(ApiPaths.events, const {}, (json, add) {
    if (json['type'] case 'changed' || 'dispatch') add(BacklogChangeEvent.fromJson(json));
  });

  @override
  Stream<AgentLogUpdateDto> followAgentLog(String reference, {int lines = 200}) =>
      _socket(ApiPaths.agentLogLive(reference), {'lines': '$lines'}, (json, add) {
        if (json['type'] == AgentLogUpdateDto.type) add(AgentLogUpdateDto.fromJson(json));
      });

  /// JSON messages of the WebSocket at [path], handed to [handle];
  /// reconnects after [reconnectDelay] while listened to.
  Stream<T> _socket<T>(String path, Map<String, String> query, void Function(Json json, void Function(T) add) handle) {
    late final StreamController<T> controller;
    WebSocketChannel? channel;
    var active = true;

    Future<void> run() async {
      while (active) {
        try {
          final socket = channel = _connectSocket(_socketUri(path, query));
          await socket.ready;
          await for (final message in socket.stream) {
            handle(asJson(jsonDecode(message as String)), controller.add);
          }
        } catch (_) {
          // Server restarting or unreachable: retry below.
        }
        if (active) await Future<void>.delayed(reconnectDelay);
      }
    }

    controller = StreamController<T>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        active = false;
        await channel?.sink.close();
      },
    );
    return controller.stream;
  }

  Uri _socketUri(String path, Map<String, String> query) {
    final uri = _uri(path, {...query, 'token': ?token});
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  /// Built from the origin only: a query or fragment left in [baseUri] (the
  /// app's `Uri.base` ends in `?#`) must not leak into requests — browsers
  /// refuse to open a WebSocket whose URL has a fragment, even an empty one.
  Uri _uri(String path, [Map<String, String> query = const {}]) => Uri(
    scheme: baseUri.scheme,
    userInfo: baseUri.userInfo,
    host: baseUri.host,
    port: baseUri.port,
    path: project == null ? path : ApiPaths.inProject(project!, path),
    queryParameters: query.isEmpty ? null : query,
  );

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

/// [ProjectsApi] over HTTP; the per-project APIs share its HTTP client.
final class HttpProjectsApi implements ProjectsApi {
  HttpProjectsApi(this.baseUri, {this.token, http.Client? client, SocketConnector? connectSocket})
    : _client = client ?? http.Client(),
      _connectSocket = connectSocket ?? WebSocketChannel.connect;

  final Uri baseUri;
  final String? token;
  final http.Client _client;
  final SocketConnector _connectSocket;
  late final _default = HttpBacklogApi(baseUri, token: token, client: _client, connectSocket: _connectSocket);

  @override
  Future<List<ProjectDto>> projects() async {
    final json = await _default._get(ApiPaths.projects);
    return HttpBacklogApi._list(json).map(ProjectDto.fromJson).toList();
  }

  @override
  Future<ProjectDto> setPinned(String id, bool pinned) async =>
      ProjectDto.fromJson(asJson(await _default._send('PATCH', ApiPaths.project(id), {'pinned': pinned})));

  @override
  Future<PreviewDto?> preview() async => switch (asJson(await _default._get(ApiPaths.preview))['preview']) {
    final Json preview => PreviewDto.fromJson(preview),
    _ => null,
  };

  @override
  Future<PreviewDto> backToMain() async =>
      PreviewDto.fromJson(asJson(await _default._send('POST', ApiPaths.previewMain, const {})));

  @override
  BacklogApi project(String id) =>
      HttpBacklogApi(baseUri, token: token, project: id, client: _client, connectSocket: _connectSocket);

  void close() => _client.close();
}
