import 'dart:convert';
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
        projects: ProjectHub.single(BacklogHost(dir.path, clock: clock)),
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
    expect(workflow.appearance.mode, 'system');
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

  test('touches: created, edited, and an overlapping open item waits', () async {
    final doing = await api.createItem(const NewItemRequest(title: 'Payments', touches: ['lib/pay/']));
    await api.claim(doing.item.id, const ClaimRequest(agent: 'm2'));
    final waiting = await api.createItem(
      const NewItemRequest(title: 'Stripe', status: 'todo', touches: ['lib/pay/stripe.dart']),
    );
    expect(waiting.item.touches, ['lib/pay/stripe.dart']);
    expect(waiting.item.conflicting, isTrue);
    expect(waiting.item.conflictsWith, [doing.item.id]);
    expect(waiting.item.ready, isFalse);
    expect(waiting.conflicts.single.title, 'Payments');
    expect((await api.item(doing.item.id)).waiting.single.id, waiting.item.id);

    final moved = await api.updateItem(
      waiting.item.id,
      ItemUpdateRequest(
        changes: [
          ItemUpdateRequest.set('touches', ['lib/stripe/', 'docs/*.{md,txt}']),
        ],
      ),
    );
    expect(moved.item.touches, ['lib/stripe/', 'docs/*.{md,txt}']);
    expect(moved.item.conflicting, isFalse);
    expect(moved.item.ready, isTrue);
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
    await expectLater(
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

  test('comments and questions: the discussion in the detail, needs a person', () async {
    final created = await api.createItem(const NewItemRequest(title: 'Export', status: 'todo', body: 'Export it.\n'));
    final id = created.item.id;
    expect(created.discussion, isEmpty);
    final asked = await api.comment(id, const CommentRequest('CSV or JSON?', author: 'w1', question: true));
    expect(asked.item.needsHuman, isTrue);
    expect(asked.item.ready, isFalse);
    expect(asked.discussion.single.question, isTrue);
    expect((await api.items()).single.needsHuman, isTrue);

    final noted = await api.comment(id, const CommentRequest('Let me think.', note: true));
    expect(noted.item.needsHuman, isTrue, reason: 'a note answers nothing');
    expect(noted.discussion.last.note, isTrue);
    expect(noted.item.body, contains(' · note\n\nLet me think.'));

    final answered = await api.comment(id, const CommentRequest('CSV.'));
    expect(answered.item.needsHuman, isFalse);
    expect(answered.discussion.map((c) => c.text), ['CSV or JSON?', 'Let me think.', 'CSV.']);
    expect(answered.discussion.last.author, isNot('w1'), reason: 'the server user or web');
    expect(answered.item.body, startsWith('Export it.\n\n## Discussion\n\n### w1 · '));
    await expectLater(api.comment(id, const CommentRequest(' ')), throwsA(apiError(400, 'invalid_input')));
  });

  test('views are listed and evaluated', () async {
    await backlog.items.create(const NewItem(title: 'Doing', status: 'in-progress', priority: 'p0'));
    final views = await api.views();
    expect(views.map((v) => v.id), containsAll(['board', 'ready', 'hot']));

    final board = await api.view('board');
    expect(board.layout, ViewLayoutDto.kanban);
    expect(board.groupBy, 'status');
    expect(board.groups.firstWhere((g) => g.key == 'in-progress').items.single.title, 'Doing');
    final named = await api.view('board', idsOnly: true);
    expect([for (final group in named.groups) ...group.items], isEmpty);
    expect([for (final group in named.groups) group.ids], [for (final group in board.groups) group.ids]);
    await expectLater(() => api.view('nope'), throwsA(apiError(404, 'not_found')));
  });

  test('a view moves between sections', () async {
    final moved = await api.updateView('board', const ViewUpdateRequest.section('Planning'));
    expect(moved.section, 'Planning');
    expect((await api.views()).firstWhere((v) => v.id == 'board').section, 'Planning');
    expect((await api.updateView('board', const ViewUpdateRequest.section(null))).section, isNull);
    await expectLater(
      () => api.updateView('nope', const ViewUpdateRequest.section('X')),
      throwsA(apiError(404, 'not_found')),
    );
  });

  test('a view gets its columns from the app and back to the default', () async {
    await api.updateView('board', const ViewUpdateRequest.columns(['review', 'todo']));
    expect((await api.view('board')).groups.map((g) => g.key), ['review', 'todo']);
    expect((await api.view('board')).columns, ['review', 'todo']);
    await api.updateView('board', const ViewUpdateRequest.columns(null));
    final restored = await api.view('board');
    expect(restored.columns, isNull);
    expect(restored.groups.map((g) => g.key), containsAll(['backlog', 'todo', 'done']));
    await expectLater(
      () => api.updateView('board', const ViewUpdateRequest()),
      throwsA(apiError(400, 'invalid_input')),
    );
  });

  test('a filter from the app is saved as a new view', () async {
    final created = await api.createItem(const NewItemRequest(title: 'Fix login', labels: ['ui'], status: 'todo'));
    await api.createItem(const NewItemRequest(title: 'Other', labels: ['ui'], status: 'todo'));
    final view = await api.createView(
      const NewViewRequest(
        name: 'UI login',
        section: 'Mine',
        base: 'board',
        conditions: [
          {
            'labels': ['ui'],
          },
          {
            'title': {'contains': 'LOGIN'},
          },
        ],
      ),
    );
    expect(view.id, 'ui-login');
    expect(view.section, 'Mine');
    expect(view.layout, ViewLayoutDto.kanban);
    final result = await api.view(view.id);
    expect(result.groups.expand((g) => g.items).map((i) => i.id), [created.item.id]);
    expect(
      () => api.createView(
        const NewViewRequest(
          name: 'X',
          conditions: [
            {
              'status': {'nope': 1},
            },
          ],
        ),
      ),
      throwsA(apiError(400, 'invalid_input')),
    );
  });

  test('views carry counts and can be pinned', () async {
    await api.createItem(const NewItemRequest(title: 'A', status: 'todo'));
    await api.createItem(const NewItemRequest(title: 'B', status: 'todo'));
    final board = (await api.views()).firstWhere((v) => v.id == 'board');
    expect(board.count, 2);
    expect(board.pinned, isFalse);
    expect((await api.updateView('board', const ViewUpdateRequest.pinned(true))).pinned, isTrue);
    expect((await api.views()).firstWhere((v) => v.id == 'board').pinned, isTrue);
    expect((await api.updateView('board', const ViewUpdateRequest.pinned(false))).pinned, isFalse);
    final saved = await api.createView(const NewViewRequest(name: 'Pinned one', pinned: true));
    expect(saved.pinned, isTrue);
  });

  test('a view can be regrouped for one request without changing it', () async {
    await api.createItem(const NewItemRequest(title: 'Urgent', status: 'todo', priority: 'p0'));
    final byPriority = await api.view('board', groupBy: 'priority');
    expect(byPriority.groupBy, 'priority');
    expect(byPriority.columns, isNull);
    expect(byPriority.groups.map((g) => g.key), containsAll(['p0', 'p1', 'p2', 'p3']));
    expect((await api.view('board')).groupBy, 'status');
    expect((await api.view('board', groupBy: '')).groups.single.key, '');
  });

  test('lint reports problems', () async {
    expect(await api.lint(), isEmpty);
    File(p.join(dir.path, 'items', 'S-zzzz-x.md')).writeAsStringSync('---\nid: S-zzzz\ntitle: X\nstatus: nope\n---\n');
    expect((await api.lint()).map((i) => i.code), contains('unknown-status'));
  });

  test('errors carry type and status', () async {
    await api.createItem(const NewItemRequest(title: 'A'));
    await api.createItem(const NewItemRequest(title: 'B'));
    await expectLater(() => api.item('zzzz'), throwsA(apiError(404, 'not_found')));
    await expectLater(() => api.item('S'), throwsA(apiError(409, 'ambiguous_reference')));
    await expectLater(
      () => api.createItem(const NewItemRequest(title: 'Bad', priority: 'p9')),
      throwsA(apiError(400, 'invalid_input')),
    );
    final a = (await api.items()).first.id;
    await expectLater(
      () => api.updateItem(a, const ItemUpdateRequest(changes: ['not an edit'])),
      throwsA(apiError(400, 'invalid_input')),
    );
  });

  test('a token protects the api but not the health check', () async {
    await expectLater(() => client(serverToken: 'secret').items(), throwsA(apiError(401, 'unauthorized')));
    expect(await client(token: 'secret', serverToken: 'secret').items(), isEmpty);
    final health = await inMemory(
      BacklogServer.buildHandler(projects: ProjectHub.single(BacklogHost(dir.path)), token: 'secret'),
    ).get(Uri.parse('http://backlog.test/api/health'));
    expect(health.statusCode, 200);
  });

  group('item cache', () {
    File itemFile(String name) => File(p.join(dir.path, 'items', name));
    void writeItem(String name, String id, String title, {String extra = ''}) =>
        itemFile(name).writeAsStringSync('---\nid: $id\ntitle: $title\n$extra---\n');
    Future<List<String>> titles() async => [for (final item in await api.items(includeDone: true)) item.title];

    test('changes on disk are seen: edits of the same size, new, renamed and deleted files', () async {
      writeItem('S-1.md', 'S-1', 'Aa');
      expect(await titles(), ['Aa']);
      for (final title in ['Bb', 'Cc']) {
        writeItem('S-1.md', 'S-1', title, extra: 'status: todo\n'); // same size, usually the same mtime
        expect(await titles(), [title]);
        expect((await api.item('S-1')).item.title, title);
        expect((await api.views()).firstWhere((view) => view.id == 'board').count, 1);
      }
      writeItem('S-2.md', 'S-2', 'New');
      expect(await titles(), unorderedEquals(['Cc', 'New']));
      itemFile('S-1.md').renameSync(itemFile('S-1-renamed.md').path);
      expect((await api.item('S-1')).item.path, 'items/S-1-renamed.md');
      itemFile('S-2.md').deleteSync();
      expect(await titles(), ['Cc']);
      await expectLater(() => api.item('S-2'), throwsA(apiError(404, 'not_found')));
    });

    test('own writes and writes of an agent through the CLI are seen at once', () async {
      final created = await api.createItem(const NewItemRequest(title: 'Mine'));
      await api.updateItem(created.item.id, ItemUpdateRequest(changes: [ItemUpdateRequest.set('title', 'Ours')]));
      expect(await titles(), ['Ours']);
      await backlog.items.update(created.item.id, [FieldChange.parse('title=Them')]);
      expect(await titles(), ['Them']);
      expect((await api.lint()).where((issue) => issue.isError), isEmpty);
    });

    test('claims are read fresh and expire with the clock', () async {
      final created = await api.createItem(const NewItemRequest(title: 'Work', status: 'todo'));
      await backlog.claims.claim(created.item.id, 'agent-1');
      final claimed = (await api.items()).single;
      expect(claimed.claim?.agent, 'agent-1');
      expect(claimed.claim?.expired, isFalse);
      clock.advance(const Duration(days: 1));
      expect((await api.items()).single.claim?.expired, isTrue);
      expect((await api.item(created.item.id)).item.claim?.expired, isTrue);
      await backlog.claims.release(created.item.id, agent: 'agent-1', force: true);
      expect((await api.items()).single.claim, isNull);
    });

    test('a changed backlog.yaml drops the cache (new defaults apply to the files)', () async {
      final host = BacklogHost(dir.path, clock: clock);
      final cached = ApiHandler(host).handler;
      Future<String> priority() async {
        final response = await cached(shelf.Request('GET', Uri.parse('http://backlog.test/items')));
        return (jsonDecode(await response.readAsString()) as List).single['priority'] as String;
      }

      writeItem('S-1.md', 'S-1', 'No priority');
      expect(await priority(), 'p2');
      final config = File(p.join(dir.path, 'backlog.yaml'));
      config.writeAsStringSync(config.readAsStringSync().replaceFirst(RegExp(r'priority: p2'), 'priority: p1'));
      host.reload();
      expect(await priority(), 'p1');
    });
  });

  test('a changed workflow applies after reload', () async {
    final host = BacklogHost(dir.path, clock: clock);
    expect((await host.backlog).workflow.priorities, hasLength(4));
    final config = File(p.join(dir.path, 'backlog.yaml'));
    config.writeAsStringSync(config.readAsStringSync().replaceFirst('[p0, p1, p2, p3]', '[p0, p1, p2]'));
    host.reload();
    expect((await host.backlog).workflow.priorities, ['p0', 'p1', 'p2']);
  });

  group('dispatch', () {
    late BacklogHost host;
    late _FakeLauncher launcher;
    late Dispatcher dispatcher;

    HttpBacklogApi dispatching() => HttpBacklogApi(
      Uri.parse('http://backlog.test'),
      client: inMemory(
        BacklogServer.buildHandler(
          projects: ProjectHub.single(host, dispatcher: dispatcher, launcher: launcher),
        ),
      ),
    );

    setUp(() async {
      final config = File(p.join(dir.path, 'backlog.yaml'));
      config.writeAsStringSync(
        '${config.readAsStringSync()}\ndispatcher:\n  worktrees: [w1, w2]\n  max_agents: 1\n  command: agent {id}\n',
      );
      host = BacklogHost(dir.path, clock: clock);
      launcher = _FakeLauncher(host);
      dispatcher = Dispatcher(
        snapshot: () async => (await host.backlog).planning.snapshot(),
        backlogRoot: dir.path,
        launcher: launcher,
        clock: clock,
      );
      addTearDown(dispatcher.close);
    });

    test('without a dispatcher section the plan is off', () async {
      File(p.join(dir.path, 'backlog.yaml')).writeAsStringSync('');
      host.reload();
      final plan = await dispatching().dispatch();
      expect(plan.configured, isFalse);
      expect(plan.canStart, isFalse);
    });

    test('the plan, a manual start, the log and a stop', () async {
      final api = dispatching();
      final a = await api.createItem(const NewItemRequest(title: 'A', status: 'todo', priority: 'p1'));
      final b = await api.createItem(const NewItemRequest(title: 'B', status: 'todo'));
      final plan = await api.dispatch();
      expect(plan.configured, isTrue);
      expect(plan.mode, 'manual');
      expect(plan.agent, 'command');
      expect(plan.maxAgents, 1);
      expect(plan.canStart, isTrue);
      expect(plan.worktrees.map((w) => w.name), ['w1', 'w2']);
      expect(plan.assignments.single.item, a.item.id);
      expect(plan.waiting, [b.item.id]);
      expect(plan.waitingReason(b.item.id), isNull, reason: 'the proposal of A reserves nothing in manual mode');

      final started = await api.startAgent(b.item.id); // not the proposed A
      expect(launcher.started, ['${b.item.id}@w1']);
      expect(started.running, 1);
      expect(started.canStart, isFalse);
      expect(started.runFor(b.item.id)!.worktree, 'w1');
      expect((await api.item(b.item.id)).item.claim!.agent, 'w1');

      expect(started.waitingReason(a.item.id), 'max_agents (1) reached');
      await expectLater(api.startAgent(a.item.id), throwsA(apiError(409, 'unavailable')));
      final log = await api.agentLog(b.item.id);
      expect(log.lines, ['working on ${b.item.id}']);
      expect(log.running, isTrue);
      await expectLater(api.agentLog(a.item.id), throwsA(apiError(404, 'not_found')));

      final stopped = await api.stopAgent(b.item.id);
      expect(launcher.stopped, [b.item.id]);
      expect(stopped.running, 0);
      await expectLater(api.stopAgent(b.item.id), throwsA(apiError(404, 'not_found')));
    });

    test('a start continues the last session of the item unless fresh', () async {
      final config = File(p.join(dir.path, 'backlog.yaml'));
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          '  command: agent {id}\n',
          '  agent: bot\n  agents:\n    bot:\n      command: bot {prompt}\n      output: claude-stream-json\n'
              '      resume: --resume {session}\n',
        ),
      );
      host.reload();
      final api = dispatching();
      final a = await api.createItem(const NewItemRequest(title: 'A', status: 'todo'));
      launcher.sessions = {
        ItemId(a.item.id): AgentSession(
          item: ItemId(a.item.id),
          id: 'sess-a',
          worktree: 'w2',
          agent: 'bot',
          startedAt: DateTime.utc(2026, 10, 29, 10),
          reason: 'was stopped by a person',
        ),
      };
      final plan = await api.dispatch();
      expect(plan.assignments.single.resume, 'sess-a');
      expect(plan.assignments.single.worktree, 'w2');
      expect(plan.sessionFor(a.item.id)!.worktree, 'w2');

      await api.startAgent(a.item.id, fresh: true);
      expect(launcher.started, ['${a.item.id}@w1']);
      await api.stopAgent(a.item.id);
      await api.startAgent(a.item.id);
      expect(launcher.started.last, '${a.item.id}@w2+resume');
    });

    test('a reply on an item in review starts its session again, in manual mode too', () async {
      final config = File(p.join(dir.path, 'backlog.yaml'));
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          '  command: agent {id}\n',
          '  agent: bot\n  agents:\n    bot:\n      command: bot {prompt}\n      output: claude-stream-json\n'
              '      resume: --resume {session}\n',
        ),
      );
      host.reload();
      final api = dispatching();
      final a = await api.createItem(const NewItemRequest(title: 'A', status: 'review'));
      launcher.sessions = {
        ItemId(a.item.id): AgentSession(
          item: ItemId(a.item.id),
          id: 'sess-a',
          worktree: 'w2',
          agent: 'bot',
          startedAt: DateTime.utc(2026, 10, 29, 10),
        ),
      };
      expect((await api.dispatch()).assignments, isEmpty);
      await api.comment(a.item.id, const CommentRequest('Why this way?', author: 'tobik'));
      await dispatcher.evaluate(); // the change feed would trigger it
      expect(launcher.started, ['${a.item.id}@w2+resume'], reason: 'a reply is an explicit instruction');
      expect((await api.item(a.item.id)).item.status, 'review', reason: 'claiming keeps an active status');
    });

    test('items that are not ready cannot be started', () async {
      final api = dispatching();
      final item = await api.createItem(const NewItemRequest(title: 'Later', status: 'backlog'));
      await expectLater(api.startAgent(item.item.id), throwsA(apiError(400, 'invalid_input')));
      await expectLater(api.startAgent('S-none'), throwsA(apiError(404, 'not_found')));
    });

    test('actions: listed in the workflow and the detail, run by name, shown in the plan', () async {
      final config = File(p.join(dir.path, 'backlog.yaml'));
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          '  command: agent {id}\n',
          '  command: agent {id}\n'
              '  repo: ../repo\n  max_worktrees: 2\n'
              '  actions:\n'
              '    - {name: Vyřeš připomínky z PR, statuses: [review], prompt: "Fix {pr}"}\n'
              '    - {name: AI review, on_enter: review, fresh: true, prompt: "Review"}\n'
              '    - {name: Testy, statuses: [review], run: [sh, -c, "mise run check"]}\n',
        ),
      );
      host.reload();
      final api = dispatching();
      final workflow = await api.workflow();
      expect(workflow.actions.map((a) => (a.name, a.kind, a.onEnter, a.agent)), [
        ('Vyřeš připomínky z PR', 'prompt', null, 'command'),
        ('AI review', 'prompt', 'review', 'command'),
        ('Testy', 'command', null, null),
      ]);
      expect(workflow.actionsIn('todo'), isEmpty);
      final item = await api.createItem(const NewItemRequest(title: 'A', status: 'review'));
      final id = item.item.id;
      expect(item.actions.map((a) => a.name), ['Vyřeš připomínky z PR', 'AI review', 'Testy']);
      final other = await api.createItem(const NewItemRequest(title: 'B', status: 'todo'));
      expect(other.actions, isEmpty);

      final plan = await api.runAction(id, 'Vyřeš připomínky z PR');
      expect(launcher.started, ['$id@w1:Vyřeš připomínky z PR']);
      final run = plan.runFor(id)!;
      expect((run.action, run.kind, run.worktree), ('Vyřeš připomínky z PR', 'agent', 'w1'));
      final claimed = await api.item(id);
      expect((claimed.item.status, claimed.item.claim!.agent), ('review', 'w1'));
      await expectLater(api.runAction(id, 'Testy'), throwsA(apiError(409, 'unavailable')));
      await expectLater(api.runAction(other.item.id, 'Testy'), throwsA(apiError(400, 'invalid_input')));
      await expectLater(api.runAction(id, 'Nope'), throwsA(apiError(404, 'not_found')));

      await launcher.stop(ItemId(id));
      final tested = await api.runAction(id, 'Testy');
      final job = tested.runs.single;
      expect((job.item, job.action, job.kind), (id, 'Testy', 'command'));
      expect(launcher.jobs.single, contains('sh -c \'mise run check\''));
    });

    test('the review state: from review comments, running while an AI review runs', () async {
      final config = File(p.join(dir.path, 'backlog.yaml'));
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          '  command: agent {id}\n',
          '  command: agent {id}\n  actions:\n    - {name: AI review, review: true, on_enter: review}\n',
        ),
      );
      host.reload();
      final api = dispatching();
      expect((await api.workflow()).actions.single.review, isTrue);
      final created = await api.createItem(const NewItemRequest(title: 'A', status: 'review'));
      final id = created.item.id;
      expect(created.item.review, 'none');

      await api.runAction(id, 'AI review');
      expect(launcher.started, ['$id@w1:AI review']);
      expect((await api.item(id)).item.review, 'running');
      expect((await api.items()).single.review, 'running');
      expect((await api.view('board')).groups.expand((g) => g.items).single.review, 'running');

      await (await host.backlog).items.comment(
        id,
        author: 'w1',
        text: 'Two things.\n\n1. a\n2. b',
        review: ReviewVerdict.changes,
      );
      await launcher.stop(ItemId(id));
      await dispatcher.evaluate();
      final detail = await api.item(id);
      expect((detail.item.review, detail.item.reviewFindings), ('changes', 2));
      expect((detail.discussion.last.review, detail.discussion.last.commit), ('changes', null));
    });

    test('start and stop need a running dispatcher', () async {
      final api = HttpBacklogApi(
        Uri.parse('http://backlog.test'),
        client: inMemory(BacklogServer.buildHandler(projects: ProjectHub.single(host))),
      );
      final item = await api.createItem(const NewItemRequest(title: 'A', status: 'todo'));
      expect((await api.dispatch()).assignments.single.item, item.item.id);
      await expectLater(api.startAgent(item.item.id), throwsA(apiError(404, 'not_found')));
    });
  });
}

/// Claims like the real launcher and pretends that an agent runs until stopped.
final class _FakeLauncher extends AgentLauncher {
  _FakeLauncher(this.host);

  final BacklogHost host;
  final started = <String>[];
  final stopped = <String>[];
  final _runs = <ItemId, AgentRun>{};
  Map<ItemId, AgentSession> sessions = const {};

  final jobs = <String>[];

  @override
  Future<void> runJob(ActionJob job) async {
    jobs.add('${job.id} in ${job.path}: ${CommandTemplate.join(job.command!)}');
    _runs[job.id] = AgentRun(
      item: job.id,
      worktree: 'repo',
      pid: 43,
      startedAt: DateTime.utc(2026, 10, 29, 12),
      log: '/logs/${job.id}.log',
      agent: job.action.name,
      action: job.action.name,
      kind: RunKind.command,
    );
  }

  @override
  Future<void> launch(DispatchAssignment assignment) async {
    final action = assignment.action;
    await (await host.backlog).claims.claim(
      assignment.id.value,
      assignment.agent,
      force: action != null,
      mirror: action == null,
    );
    started.add(assignment.key);
    _runs[assignment.id] = AgentRun(
      item: assignment.id,
      worktree: assignment.agent,
      pid: 42,
      startedAt: DateTime.utc(2026, 10, 29, 12),
      log: '/logs/${assignment.id}.log',
      agent: assignment.agentProfile.name,
      action: action?.name,
    );
  }

  @override
  Future<DispatchConditions> conditions(DispatcherConfig config, String backlogRoot, BacklogSnapshot snapshot) async =>
      DispatchConditions(runs: _runs.values.toList(), sessions: sessions);

  @override
  Future<bool> stop(ItemId item) async {
    final run = _runs.remove(item);
    if (run == null) return false;
    stopped.add(item.value);
    if (run.action != null) {
      await (await host.backlog).claims.drop(item.value, run.worktree);
    } else {
      await (await host.backlog).claims.release(item.value, agent: run.worktree);
    }
    return true;
  }

  @override
  Future<AgentLog?> agentLog(ItemId item, {int lines = 100}) async =>
      _runs.containsKey(item) ? AgentLog(path: _runs[item]!.log, lines: ['working on $item'], running: true) : null;
}
