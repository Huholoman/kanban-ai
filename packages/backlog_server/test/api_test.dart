import 'dart:async';
import 'dart:io';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_server/backlog_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// Routes [HttpBacklogApi] straight into the shelf pipeline: the real client
/// and the real server, without sockets.
http.Client inMemory(shelf.Handler handler) => MockClient((request) async {
  final response = await handler(
    shelf.Request(request.method, request.url, headers: request.headers, body: request.bodyBytes),
  );
  return http.Response.bytes(
    await response.read().expand((chunk) => chunk).toList(),
    response.statusCode,
    headers: response.headers,
  );
});

void main() {
  late Directory dir;
  late Backlog backlog;
  late HttpBacklogApi api;
  final clock = FixedClock(DateTime.utc(2026, 10, 29, 12));

  HttpBacklogApi client({String? token, String? serverToken}) => HttpBacklogApi(
    Uri.parse('http://backlog.test'),
    token: token,
    client: inMemory(
      BacklogServer.buildHandler(
        host: BacklogHost(dir.path, clock: clock),
        events: const Stream.empty(),
        token: serverToken,
      ),
    ),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('backlog_server_');
    await Backlog.init(dir.path, idPrefix: 'S');
    backlog = await Backlog.open(dir.path, clock: clock);
    api = client();
  });

  tearDown(() => dir.delete(recursive: true));

  Matcher apiError(int status, String type) =>
      isA<BacklogApiException>().having((e) => e.statusCode, 'statusCode', status).having((e) => e.type, 'type', type);

  test('workflow describes the allowed values', () async {
    final workflow = await api.workflow();
    expect(workflow.statuses.map((s) => s.id), contains('in-progress'));
    expect(workflow.categoryOf('done'), StatusCategoryDto.done);
    expect(workflow.priorities, ['p0', 'p1', 'p2', 'p3']);
    expect(workflow.defaultStatus, 'backlog');
  });

  test('create, list and detail with relations', () async {
    final epic = (await api.createItem(const NewItemRequest(title: 'Payments', type: 'epic'))).item;
    final first = await api.createItem(NewItemRequest(title: 'Gateway', status: 'todo', parent: epic.id));
    final second = await api.createItem(
      NewItemRequest(title: 'Invoices', status: 'todo', parent: epic.id, dependsOn: [first.item.id], body: '- [ ] a'),
    );

    expect(second.item.blocked, isTrue);
    expect(second.item.blockedBy, [first.item.id]);
    expect(second.item.checklist.total, 1);
    expect(second.item.path, startsWith('items/${second.item.id}-invoices'));
    expect(second.parent!.title, 'Payments');
    expect(second.dependencies.single.id, first.item.id);

    final listed = await api.items();
    expect(listed.map((i) => i.id), containsAll([epic.id, first.item.id, second.item.id]));
    expect(listed.firstWhere((i) => i.id == epic.id).children.total, 2);

    final detail = await api.item(first.item.id.substring(2));
    expect(detail.dependents.single.id, second.item.id);
    expect(detail.item.body, '');
  });

  test('update edits fields and body and keeps the file tidy', () async {
    final created = await api.createItem(const NewItemRequest(title: 'Edit me', labels: ['ui']));
    final updated = await api.updateItem(
      created.item.id,
      ItemUpdateRequest(
        changes: [ItemUpdateRequest.set('status', 'review'), ItemUpdateRequest.add('labels', 'web')],
        body: '## Notes\n- [x] done\n',
      ),
    );
    expect(updated.item.status, 'review');
    expect(updated.item.labels, ['ui', 'web']);
    expect(updated.item.checklist.done, 1);
    final file = File(p.join(dir.path, updated.item.path!)).readAsStringSync();
    expect(file, contains('labels: [ui, web]'));
    expect(file, endsWith('## Notes\n- [x] done\n'));
  });

  test('claim, conflict, release and done', () async {
    final first = await api.createItem(const NewItemRequest(title: 'One', status: 'todo'));
    final second = await api.createItem(NewItemRequest(title: 'Two', status: 'todo', dependsOn: [first.item.id]));

    final claimed = await api.claim(first.item.id, const ClaimRequest(agent: 'tobik'));
    expect(claimed.item.status, 'in-progress');
    expect(claimed.item.claim!.agent, 'tobik');
    expect(
      () => api.claim(first.item.id, const ClaimRequest(agent: 'other')),
      throwsA(apiError(409, 'claim_conflict')),
    );

    final released = await api.release(first.item.id, const ClaimRequest(agent: 'tobik'));
    expect(released.item.status, 'todo');
    expect(released.item.claim, isNull);

    final done = await api.complete(first.item.id, const ClaimRequest(force: true));
    expect(done.item.isDone, isTrue);
    expect((await api.item(second.item.id)).item.ready, isTrue);
    expect((await api.items()).map((i) => i.id), isNot(contains(first.item.id)));
    expect((await api.items(includeDone: true)).map((i) => i.id), contains(first.item.id));
  });

  test('views are listed and evaluated', () async {
    await backlog.items.create(const NewItem(title: 'Doing', status: 'in-progress', priority: 'p0'));
    final views = await api.views();
    expect(views.map((v) => v.id), containsAll(['board', 'ready', 'hot']));

    final board = await api.view('board');
    expect(board.layout, ViewLayoutDto.kanban);
    expect(board.groupBy, 'status');
    expect(board.groups.firstWhere((g) => g.key == 'in-progress').items.single.title, 'Doing');
    expect(() => api.view('nope'), throwsA(apiError(404, 'not_found')));
  });

  test('a view moves between sections', () async {
    final moved = await api.updateView('board', const ViewUpdateRequest(section: 'Planning'));
    expect(moved.section, 'Planning');
    expect((await api.views()).firstWhere((v) => v.id == 'board').section, 'Planning');
    expect((await api.updateView('board', const ViewUpdateRequest())).section, isNull);
    expect(() => api.updateView('nope', const ViewUpdateRequest(section: 'X')), throwsA(apiError(404, 'not_found')));
  });

  test('lint reports problems', () async {
    expect(await api.lint(), isEmpty);
    File(p.join(dir.path, 'items', 'S-zzzz-x.md')).writeAsStringSync('---\nid: S-zzzz\ntitle: X\nstatus: nope\n---\n');
    expect((await api.lint()).map((i) => i.code), contains('unknown-status'));
  });

  test('errors carry type and status', () async {
    await api.createItem(const NewItemRequest(title: 'A'));
    await api.createItem(const NewItemRequest(title: 'B'));
    expect(() => api.item('zzzz'), throwsA(apiError(404, 'not_found')));
    expect(() => api.item('S'), throwsA(apiError(409, 'ambiguous_reference')));
    expect(
      () => api.createItem(const NewItemRequest(title: 'Bad', priority: 'p9')),
      throwsA(apiError(400, 'invalid_input')),
    );
    final a = (await api.items()).first.id;
    expect(
      () => api.updateItem(a, const ItemUpdateRequest(changes: ['not an edit'])),
      throwsA(apiError(400, 'invalid_input')),
    );
  });

  test('a token protects the api but not the health check', () async {
    expect(() => client(serverToken: 'secret').items(), throwsA(apiError(401, 'unauthorized')));
    expect(await client(token: 'secret', serverToken: 'secret').items(), isEmpty);
    final health = await inMemory(
      BacklogServer.buildHandler(host: BacklogHost(dir.path), events: const Stream.empty(), token: 'secret'),
    ).get(Uri.parse('http://backlog.test/api/health'));
    expect(health.statusCode, 200);
  });

  test('a changed workflow applies after reload', () async {
    final host = BacklogHost(dir.path, clock: clock);
    expect((await host.backlog).workflow.priorities, hasLength(4));
    final config = File(p.join(dir.path, 'backlog.yaml'));
    config.writeAsStringSync(config.readAsStringSync().replaceFirst('[p0, p1, p2, p3]', '[p0, p1, p2]'));
    host.reload();
    expect((await host.backlog).workflow.priorities, ['p0', 'p1', 'p2']);
  });
}
