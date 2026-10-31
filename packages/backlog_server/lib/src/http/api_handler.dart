import 'dart:convert';
import 'dart:io';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../backlog_host.dart';
import '../events/agent_log_socket.dart';
import 'dto_mapper.dart';

/// REST endpoints of [ApiPaths] for one project. A driving adapter: it parses requests, calls
/// the core services and maps the results to the API contract.
final class ApiHandler {
  ApiHandler(
    this._host, {
    this.defaultAgent = 'web',
    String? defaultAuthor,
    this.agentLogInterval = const Duration(milliseconds: 500),
    Dispatcher? Function()? dispatcher,
    AgentLauncher? Function()? launcher,
  }) : defaultAuthor = defaultAuthor ?? Platform.environment['USER'] ?? defaultAgent,
       _dispatcher = dispatcher ?? (() => null),
       _launcher = launcher ?? (() => null);

  final BacklogHost _host;

  /// The project's dispatcher and launcher, once they run (null before, and
  /// for projects without them).
  final Dispatcher? Function() _dispatcher;
  final AgentLauncher? Function() _launcher;

  /// Who claims items when a request does not name an agent.
  final String defaultAgent;

  /// Who comments when a request does not name an author: the server's user
  /// (`$USER`), else [defaultAgent].
  final String defaultAuthor;

  /// How often a followed agent log is checked for new lines.
  final Duration agentLogInterval;

  /// Routes relative to the project's prefix (`/api` or `/api/p/<id>`): the
  /// request's `url` is `items`, `views/board`, … (see `ProjectHub`).
  Handler get handler {
    String local(String path) => path.substring('/api'.length);
    final items = local(ApiPaths.items);
    final views = local(ApiPaths.views);
    final router =
        Router(notFoundHandler: (request) => _error(BacklogApiException(404, 'not_found', 'No such endpoint.')))
          ..get(local(ApiPaths.workflow), _workflow)
          ..get(items, _items)
          ..post(items, _create)
          ..get('$items/<ref>', _detail)
          ..patch('$items/<ref>', _update)
          ..post('$items/<ref>/claim', _claim)
          ..post('$items/<ref>/release', _release)
          ..post('$items/<ref>/done', _complete)
          ..post('$items/<ref>/comments', _comment)
          ..post('$items/<ref>/actions/<name>', _runAction)
          ..get('$items/<ref>/epic', _epic)
          ..get(views, _views)
          ..post(views, _createView)
          ..get('$views/<id>', _view)
          ..patch('$views/<id>', _updateView)
          ..get(local(ApiPaths.lint), _lint)
          ..get(local(ApiPaths.dispatch), _dispatch)
          ..post(local(ApiPaths.dispatchStart), _startAgent)
          ..post(local(ApiPaths.dispatchStop), _stopAgent)
          ..post(local(ApiPaths.dispatchEpic), _startEpic)
          ..get('${local(ApiPaths.dispatch)}/log/<ref>', _agentLog)
          ..get('${local(ApiPaths.dispatch)}/log/<ref>/live', _agentLogLive);
    return _guard(router.call);
  }

  Future<Response> _workflow(Request request) async => _json(DtoMapper.workflow((await _host.backlog).workflow));

  Future<Response> _items(Request request) async {
    final snapshot = await (await _host.backlog).planning.snapshot();
    final includeDone = request.url.queryParameters['all'] == 'true';
    return _json([
      for (final planned in snapshot.items)
        if (includeDone || !planned.isDone) DtoMapper.item(planned, reviewing: _reviewing).toJson(),
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
        touches: payload.touches,
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

  Future<Response> _comment(Request request, String ref) async {
    final payload = CommentRequest.fromJson(await _body(request));
    final backlog = await _host.backlog;
    final item = await backlog.items.comment(
      ref,
      author: payload.author ?? defaultAuthor,
      text: payload.text,
      question: payload.question,
      note: payload.note,
    );
    return _detailOf(backlog, item.id.value);
  }

  Future<Response> _views(Request request) async {
    final counts = await (await _host.backlog).views.counts();
    return _json([for (final (view, count) in counts) DtoMapper.viewSummary(view, count: count).toJson()]);
  }

  Future<Response> _view(Request request, String id) async => _json(
    DtoMapper.view(
      await (await _host.backlog).views.run(id, groupBy: request.url.queryParameters['group_by']),
      reviewing: _reviewing,
    ).toJson(),
  );

  Future<Response> _createView(Request request) async {
    final payload = NewViewRequest.fromJson(await _body(request));
    final view = await (await _host.backlog).views.saveAs(
      name: payload.name,
      section: payload.section,
      pinned: payload.pinned,
      base: payload.base,
      conditions: payload.conditions,
    );
    return _json(DtoMapper.viewSummary(view).toJson(), status: 201);
  }

  Future<Response> _updateView(Request request, String id) async {
    final payload = ViewUpdateRequest.fromJson(await _body(request));
    final views = (await _host.backlog).views;
    if (!payload.changesSection && !payload.changesColumns && payload.pinned == null) {
      throw const InvalidInputException('Nothing to change: give "section", "columns" and/or "pinned".');
    }
    var view = payload.changesSection ? await views.setSection(id, payload.section) : null;
    if (payload.changesColumns) view = await views.setColumns(id, payload.columns);
    if (payload.pinned case final pinned?) view = await views.setPinned(id, pinned);
    return _json(DtoMapper.viewSummary(view!).toJson());
  }

  Future<Response> _lint(Request request) async {
    final issues = await (await _host.backlog).linter.run();
    return _json([for (final issue in issues) DtoMapper.lintIssue(issue).toJson()]);
  }

  Future<Response> _dispatch(Request request) async => _json((await _plan()).toJson());

  /// The dispatcher's latest plan, or one computed from the files when no
  /// dispatcher runs (without its knowledge of processes and worktrees).
  Future<DispatchDto> _plan() async {
    final dispatcher = _dispatcher();
    final plan = dispatcher == null
        ? DispatchPlan.of(await (await _host.backlog).planning.snapshot(), backlogRoot: _host.root)
        : dispatcher.current ?? await dispatcher.evaluate();
    return plan == null ? DispatchDto.off : DtoMapper.dispatch(plan);
  }

  /// Items an AI review runs or waits to run for, by the dispatcher's
  /// latest plan (none without a running dispatcher).
  Set<ItemId> get _reviewing => _dispatcher()?.current?.reviewing ?? const {};

  Dispatcher _running() => _dispatcher() ?? (throw const NotFoundException('No dispatcher runs for this project.'));

  Future<Response> _startAgent(Request request) async {
    final payload = DispatchRequest.fromJson(await _body(request));
    await _running().start(payload.item, fresh: payload.fresh);
    return _json((await _plan()).toJson());
  }

  /// As seen by whoever implements the epic (the holder of its claim, else
  /// the worktree of the agent running for it): its own claims are no
  /// problem and its item in progress is next.
  Future<Response> _epic(Request request, String ref) async {
    final snapshot = await (await _host.backlog).planning.snapshot();
    final epic = snapshot[ItemReference.resolve(ref, snapshot.ids)]!;
    final agent = epic.isClaimed ? epic.claim!.agent : _dispatcher()?.current?.runFor(epic.id)?.worktree;
    return _json(DtoMapper.epic(EpicPlan.of(snapshot, epic.id, agent: agent)).toJson());
  }

  Future<Response> _startEpic(Request request) async {
    final payload = DispatchRequest.fromJson(await _body(request));
    await _running().startEpic(payload.item, fresh: payload.fresh);
    return _json((await _plan()).toJson());
  }

  Future<Response> _runAction(Request request, String ref, String name) async {
    await _running().runAction(ref, Uri.decodeComponent(name));
    return _json((await _plan()).toJson());
  }

  Future<Response> _stopAgent(Request request) async {
    final payload = DispatchRequest.fromJson(await _body(request));
    if (!await _running().stop(payload.item)) throw NotFoundException('No agent runs for ${payload.item}.');
    return _json((await _plan()).toJson());
  }

  Future<Response> _agentLog(Request request, String ref) async {
    final snapshot = await (await _host.backlog).planning.snapshot();
    final id = ItemReference.resolve(ref, snapshot.ids);
    final lines = int.tryParse(request.url.queryParameters['lines'] ?? '') ?? 100;
    final log = await _launcher()?.agentLog(id, lines: lines.clamp(1, 2000));
    if (log == null) throw NotFoundException('No agent has run for $id.');
    return _json(
      AgentLogDto(
        item: id.value,
        path: log.path,
        running: log.running,
        lines: log.lines,
        last: log.last == null ? null : AgentRunEndDto.fromJson(log.last!),
      ).toJson(),
    );
  }

  /// Upgrades to a WebSocket that follows the agent log of [ref].
  Future<Response> _agentLogLive(Request request, String ref) async {
    final snapshot = await (await _host.backlog).planning.snapshot();
    final id = ItemReference.resolve(ref, snapshot.ids);
    final launcher = _launcher() ?? (throw const NotFoundException('No dispatcher runs for this project.'));
    final lines = int.tryParse(request.url.queryParameters['lines'] ?? '') ?? 200;
    final follower = AgentLogFollower(() => launcher.agentLogSource(id), item: id.value, lines: lines.clamp(1, 2000));
    return agentLogSocketHandler(follower, interval: agentLogInterval)(request);
  }

  Future<Response> _detailOf(Backlog backlog, String ref, {int status = 200}) async {
    final snapshot = await backlog.planning.snapshot();
    final planned = snapshot[ItemReference.resolve(ref, snapshot.ids)]!;
    final location = await backlog.items.locationOf(planned.id);
    final path = location == null ? null : backlog.layout.relative(location);
    return _json(
      DtoMapper.detail(planned, snapshot, path: path, reviewing: _reviewing).toJson(),
      status: status,
    );
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
