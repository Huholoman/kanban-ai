import 'dart:convert';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../backlog_host.dart';
import 'dto_mapper.dart';

/// REST endpoints of [ApiPaths]. A driving adapter: it parses requests, calls
/// the core services and maps the results to the API contract.
final class ApiHandler {
  ApiHandler(this._host, {this.defaultAgent = 'web'});

  final BacklogHost _host;

  /// Who claims items when a request does not name an agent.
  final String defaultAgent;

  Handler get handler {
    final router =
        Router(notFoundHandler: (request) => _error(BacklogApiException(404, 'not_found', 'No such endpoint.')))
          ..get(ApiPaths.health, (Request request) => _json({'ok': true}))
          ..get(ApiPaths.workflow, _workflow)
          ..get(ApiPaths.items, _items)
          ..post(ApiPaths.items, _create)
          ..get('${ApiPaths.items}/<ref>', _detail)
          ..patch('${ApiPaths.items}/<ref>', _update)
          ..post('${ApiPaths.items}/<ref>/claim', _claim)
          ..post('${ApiPaths.items}/<ref>/release', _release)
          ..post('${ApiPaths.items}/<ref>/done', _complete)
          ..get(ApiPaths.views, _views)
          ..post(ApiPaths.views, _createView)
          ..get('${ApiPaths.views}/<id>', _view)
          ..patch('${ApiPaths.views}/<id>', _updateView)
          ..get(ApiPaths.lint, _lint);
    return _guard(router.call);
  }

  Future<Response> _workflow(Request request) async => _json(DtoMapper.workflow((await _host.backlog).workflow));

  Future<Response> _items(Request request) async {
    final snapshot = await (await _host.backlog).planning.snapshot();
    final includeDone = request.url.queryParameters['all'] == 'true';
    return _json([
      for (final planned in snapshot.items)
        if (includeDone || !planned.isDone) DtoMapper.item(planned).toJson(),
    ]);
  }

  Future<Response> _create(Request request) async {
    final payload = NewItemRequest.fromJson(await _body(request));
    final backlog = await _host.backlog;
    final item = await backlog.items.create(
      NewItem(
        title: payload.title,
        type: payload.type,
        status: payload.status,
        priority: payload.priority,
        milestone: payload.milestone,
        parent: payload.parent,
        dependsOn: payload.dependsOn,
        labels: payload.labels,
        body: payload.body,
      ),
    );
    return _detailOf(backlog, item.id.value, status: 201);
  }

  Future<Response> _detail(Request request, String ref) async => _detailOf(await _host.backlog, ref);

  Future<Response> _update(Request request, String ref) async {
    final payload = ItemUpdateRequest.fromJson(await _body(request));
    final backlog = await _host.backlog;
    final item = await backlog.items.update(ref, payload.changes.map(FieldChange.parse), body: payload.body);
    return _detailOf(backlog, item.id.value);
  }

  Future<Response> _claim(Request request, String ref) async {
    final payload = ClaimRequest.fromJson(await _body(request));
    final backlog = await _host.backlog;
    final outcome = await backlog.claims.claim(ref, payload.agent ?? defaultAgent, force: payload.force);
    return _detailOf(backlog, outcome.item.id.value);
  }

  Future<Response> _release(Request request, String ref) async {
    final payload = ClaimRequest.fromJson(await _body(request));
    final backlog = await _host.backlog;
    final item = await backlog.claims.release(ref, agent: payload.agent, status: payload.status, force: payload.force);
    return _detailOf(backlog, item.id.value);
  }

  Future<Response> _complete(Request request, String ref) async {
    final payload = ClaimRequest.fromJson(await _body(request));
    final backlog = await _host.backlog;
    final item = await backlog.claims.complete(ref, agent: payload.agent, status: payload.status, force: payload.force);
    return _detailOf(backlog, item.id.value);
  }

  Future<Response> _views(Request request) async {
    final views = await (await _host.backlog).views.all();
    return _json([for (final view in views) DtoMapper.viewSummary(view).toJson()]);
  }

  Future<Response> _view(Request request, String id) async =>
      _json(DtoMapper.view(await (await _host.backlog).views.run(id)).toJson());

  Future<Response> _createView(Request request) async {
    final payload = NewViewRequest.fromJson(await _body(request));
    final view = await (await _host.backlog).views.saveAs(
      name: payload.name,
      section: payload.section,
      base: payload.base,
      conditions: payload.conditions,
    );
    return _json(DtoMapper.viewSummary(view).toJson(), status: 201);
  }

  Future<Response> _updateView(Request request, String id) async {
    final payload = ViewUpdateRequest.fromJson(await _body(request));
    final views = (await _host.backlog).views;
    if (!payload.changesSection && !payload.changesColumns) {
      throw const InvalidInputException('Nothing to change: give "section" and/or "columns".');
    }
    var view = payload.changesSection ? await views.setSection(id, payload.section) : null;
    if (payload.changesColumns) view = await views.setColumns(id, payload.columns);
    return _json(DtoMapper.viewSummary(view!).toJson());
  }

  Future<Response> _lint(Request request) async {
    final issues = await (await _host.backlog).linter.run();
    return _json([for (final issue in issues) DtoMapper.lintIssue(issue).toJson()]);
  }

  Future<Response> _detailOf(Backlog backlog, String ref, {int status = 200}) async {
    final snapshot = await backlog.planning.snapshot();
    final planned = snapshot[ItemReference.resolve(ref, snapshot.ids)]!;
    final location = await backlog.items.locate(planned.id.value);
    final path = location == null ? null : backlog.layout.relative(location);
    return _json(DtoMapper.detail(planned, snapshot, path: path).toJson(), status: status);
  }

  static Future<Json> _body(Request request) async {
    final text = await request.readAsString();
    if (text.trim().isEmpty) return const {};
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (error) {
      throw InvalidInputException('Request body is not JSON: ${error.message}');
    }
    if (json is Map<String, Object?>) return json;
    throw const InvalidInputException('Request body must be a JSON object.');
  }

  /// Turns domain and payload errors into JSON error responses.
  static Handler _guard(Handler inner) => (request) async {
    try {
      return await inner(request);
    } on BacklogException catch (error) {
      return _error(DtoMapper.error(error));
    } on MalformedPayloadException catch (error) {
      return _error(BacklogApiException(400, 'invalid_input', error.message));
    }
  };

  static Response _error(BacklogApiException error) => _json(error.toJson(), status: error.statusCode);

  static Response _json(Object? body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'},
  );
}
