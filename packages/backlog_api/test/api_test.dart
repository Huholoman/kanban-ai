import 'dart:convert';

import 'package:backlog_api/backlog_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('DTOs survive a JSON round trip', () {
    test('dispatch plan, agent log and the dispatch event', () {
      final plan = DispatchDto(
        configured: true,
        mode: 'manual',
        agent: 'claude',
        maxAgents: 2,
        running: 1,
        capacity: 1,
        worktrees: [
          DispatchWorktreeDto(
            name: 'w1',
            path: '/w/w1',
            busy: true,
            claims: const ['X-1'],
            run: AgentRunDto(
              item: 'X-1',
              worktree: 'w1',
              pid: 7,
              startedAt: DateTime.utc(2026, 10, 31, 12),
              log: '/l/X-1.log',
              agent: 'claude',
              branch: 'agent/X-1',
            ),
          ),
          const DispatchWorktreeDto(name: 'w2', path: '/w/w2', busy: false, unavailable: 'uncommitted changes'),
        ],
        assignments: const [
          DispatchAssignmentDto(item: 'X-2', title: 'Two', worktree: 'w2', resume: 'sess-2'),
          DispatchAssignmentDto(item: 'X-5', title: 'Five', worktree: 'app-3', newWorktree: true),
        ],
        maxWorktrees: 3,
        spareWorktrees: 0,
        waiting: const ['X-3'],
        waitingReasons: const [HeldItemDto(item: 'X-3', title: 'Three', reason: 'no free worktree')],
        held: const [HeldItemDto(item: 'X-4', title: 'Four', reason: 'stopped')],
        problems: const [
          ProblemItemDto(item: 'X-6', title: 'Six', problems: ['the agent exited with code 1']),
        ],
        queuedReplies: const [
          HeldItemDto(item: 'X-1', title: 'One', reason: 'the agent reads it after its current run'),
        ],
        sessions: [
          AgentSessionDto(item: 'X-4', session: 'sess-4', worktree: 'w1', endedAt: DateTime.utc(2026), reason: 'x'),
        ],
      );
      final copy = DispatchDto.fromJson(jsonDecode(jsonEncode(plan.toJson())) as Json);
      expect(copy.toJson(), plan.toJson());
      expect(copy.runFor('X-1')!.startedAt, DateTime.utc(2026, 10, 31, 12));
      expect(copy.heldReason('X-4'), 'stopped');
      expect(copy.waitingReason('X-3'), 'no free worktree');
      expect(copy.waitingReason('X-4'), isNull);
      expect(copy.problemsOf('X-6'), ['the agent exited with code 1']);
      expect(copy.problemsOf('X-4'), isEmpty);
      expect(copy.queuedReplyOf('X-1'), 'the agent reads it after its current run');
      expect(copy.queuedReplyOf('X-2'), isNull);
      expect(copy.sessionFor('X-4')!.session, 'sess-4');
      expect(copy.sessionFor('X-2'), isNull);
      expect(copy.assignments.map((a) => (a.resume, a.newWorktree)), [('sess-2', false), (null, true)]);
      expect((copy.maxWorktrees, copy.spareWorktrees), (3, 0));
      expect(copy.canStart, isFalse, reason: 'w2 is unavailable, no worktree may be created');
      expect(DispatchDto.fromJson(DispatchDto.off.toJson()).configured, isFalse);

      final log = AgentLogDto(
        item: 'X-1',
        path: '/l',
        running: false,
        lines: const ['a'],
        last: AgentRunEndDto(
          exitCode: 0,
          outcome: 'review',
          endedAt: DateTime.utc(2026),
          sessionId: 's',
          result: 'Done.',
          problems: const ['a tool call was denied: WebFetch'],
        ),
      );
      final logCopy = AgentLogDto.fromJson(jsonDecode(jsonEncode(log.toJson())) as Json);
      expect(logCopy.toJson(), log.toJson());
      expect(logCopy.last!.result, 'Done.');
      expect(logCopy.last!.problems, ['a tool call was denied: WebFetch']);
      expect(BacklogChangeEvent.fromJson(const BacklogChangeEvent.dispatch().toJson()).isDispatch, isTrue);
      expect(
        BacklogChangeEvent.fromJson(const {
          'type': 'changed',
          'paths': ['a'],
        }).isDispatch,
        isFalse,
      );
    });

    final claim = ClaimDto(
      item: 'T-1',
      agent: 'm2',
      claimedAt: DateTime.utc(2026, 10, 29, 10),
      heartbeatAt: DateTime.utc(2026, 10, 29, 11),
      expiresAt: DateTime.utc(2026, 10, 29, 15),
    );
    final item = ItemDto(
      id: 'T-1',
      title: 'Backups',
      type: 'task',
      status: 'in-progress',
      category: StatusCategoryDto.active,
      priority: 'p0',
      milestone: 'launch',
      dependsOn: const ['T-2'],
      labels: const ['infra'],
      extra: const {'estimate': '3d'},
      created: '2026-10-30',
      updated: '2026-10-31T20:27:12Z',
      updatedAt: DateTime.utc(2026, 10, 31, 20, 27, 12),
      blocked: true,
      blockedBy: const ['T-2'],
      touches: const ['lib/*.{dart,yaml}'],
      conflicting: true,
      conflictsWith: const ['T-3'],
      children: const Progress(1, 3),
      checklist: const Progress(2, 5),
      claim: claim,
      needsHuman: true,
      review: 'changes',
      reviewFindings: 2,
      path: 'items/T-1-backups.md',
      body: '# Body',
    );

    T roundTrip<T>(Json json, T Function(Json) decode) => decode(jsonDecode(jsonEncode(json)) as Json);

    test('item', () {
      final copy = roundTrip(item.toJson(), ItemDto.fromJson);
      expect(copy.toJson(), item.toJson());
      expect(copy.children.toString(), '1/3');
      expect(copy.isClaimed, isTrue);
      expect(copy.createdAt, isNull);
      expect(copy.updatedAt, DateTime.utc(2026, 10, 31, 20, 27, 12));
    });

    test('detail, view and workflow', () {
      final detail = ItemDetailDto(
        item: item,
        parent: const ItemLinkDto(id: 'T-0', title: 'Epic', status: 'todo', category: StatusCategoryDto.open),
        dependencies: const [ItemLinkDto(id: 'T-9')],
        conflicts: const [ItemLinkDto(id: 'T-3', title: 'Other', status: 'review')],
        waiting: const [ItemLinkDto(id: 'T-4', title: 'Later', status: 'todo')],
        discussion: [
          CommentDto(author: 'w1', at: DateTime.utc(2026, 10, 31, 14), text: 'Which?', question: true),
          CommentDto(
            author: 'w2',
            at: DateTime.utc(2026, 10, 31, 15),
            text: 'Fix:\n\n1. a\n2. b',
            review: 'changes',
            commit: '1a2b3c4d5e6f',
          ),
        ],
      );
      final detailCopy = roundTrip(detail.toJson(), ItemDetailDto.fromJson);
      expect(detailCopy.toJson(), detail.toJson());
      expect(detailCopy.item.needsHuman, isTrue);
      expect(detailCopy.discussion.first.at, DateTime.utc(2026, 10, 31, 14));
      expect((detailCopy.item.review, detailCopy.item.reviewFindings), ('changes', 2));
      final review = detailCopy.discussion.last;
      expect((review.review, review.commit, review.findings), ('changes', '1a2b3c4d5e6f', 2));
      expect(ItemDto.fromJson({...item.toJson()}..remove('review')).review, 'none', reason: 'older servers');
      final request = roundTrip(
        const CommentRequest('Hi', author: 'a', question: true).toJson(),
        CommentRequest.fromJson,
      );
      expect((request.text, request.author, request.question), ('Hi', 'a', true));
      expect(detailCopy.dependencies.single.isMissing, isTrue);

      final view = ViewResultDto(
        id: 'board',
        name: 'Board',
        layout: ViewLayoutDto.kanban,
        groupBy: 'status',
        hidden: 2,
        groups: [
          ViewGroupDto('in-progress', [item]),
          const ViewGroupDto('done', []),
        ],
      );
      expect(roundTrip(view.toJson(), ViewResultDto.fromJson).toJson(), view.toJson());

      const workflow = WorkflowDto(
        statuses: [StatusDto(id: 'todo', category: StatusCategoryDto.open, pickable: true)],
        priorities: ['p0'],
        types: ['task'],
        milestones: [MilestoneDto(id: 'launch', title: 'Launch')],
        defaultStatus: 'todo',
        defaultPriority: 'p0',
        defaultType: 'task',
        appearance: AppearanceDto(
          mode: 'dark',
          light: PaletteDto(seed: '#3f51b5'),
          statuses: {'todo': '#1e88e5'},
          labels: {'ui': '#d81b60'},
        ),
      );
      expect(roundTrip(workflow.toJson(), WorkflowDto.fromJson).toJson(), workflow.toJson());
      expect(
        WorkflowDto.fromJson(
          jsonDecode(jsonEncode({...workflow.toJson()}..remove('appearance'))) as Map<String, Object?>,
        ).appearance.mode,
        'system',
      );
    });

    test('update request helpers write the CLI syntax', () {
      expect(ItemUpdateRequest.set('status', 'done'), 'status=done');
      expect(ItemUpdateRequest.set('labels', ['a', 'b']), 'labels=a,b');
      expect(ItemUpdateRequest.set('milestone', null), 'milestone=');
      expect(ItemUpdateRequest.add('labels', 'x'), 'labels+=x');
      expect(ItemUpdateRequest.remove('depends_on', 'T-1'), 'depends_on-=T-1');
    });

    test('a malformed payload is reported', () {
      expect(() => ItemDto.fromJson({'id': 1}), throwsA(isA<MalformedPayloadException>()));
    });
  });

  group('HttpBacklogApi', () {
    test('sends the token and decodes errors', () async {
      late http.BaseRequest seen;
      final api = HttpBacklogApi(
        Uri.parse('http://server:8640'),
        token: 't0k',
        client: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(const BacklogApiException(404, 'not_found', 'No item "x".').toJson()),
            404,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await expectLater(
        api.item('a b'),
        throwsA(isA<BacklogApiException>().having((e) => e.type, 'type', 'not_found')),
      );
      expect(seen.url.toString(), 'http://server:8640/api/items/a%20b');
      expect(seen.headers['authorization'], 'Bearer t0k');
    });

    test('network failures and non-JSON answers become api errors', () async {
      final unreachable = HttpBacklogApi(
        Uri.parse('http://server'),
        client: MockClient((_) => throw http.ClientException('refused')),
      );
      await expectLater(
        unreachable.views(),
        throwsA(isA<BacklogApiException>().having((e) => e.type, 'type', 'network')),
      );

      final proxy = HttpBacklogApi(
        Uri.parse('http://server'),
        client: MockClient((_) async => http.Response('<html>', 502)),
      );
      await expectLater(proxy.views(), throwsA(isA<BacklogApiException>().having((e) => e.statusCode, 'status', 502)));
    });

    test('drops the query and fragment of the base address', () async {
      // The app passes Uri.base with an emptied query and fragment (`/?#`).
      final base = Uri.parse('http://server:8640/board?token=t0k#x').replace(path: '/', query: '', fragment: '');
      final requested = <Uri>[];
      final api = HttpBacklogApi(
        base,
        token: 't0k',
        client: MockClient((request) async {
          requested.add(request.url);
          return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        }),
        connectSocket: (uri) {
          requested.add(uri);
          throw StateError('no socket in tests');
        },
        reconnectDelay: const Duration(hours: 1),
      );
      await api.views();
      final subscription = api.changes().listen(null);
      await pumpEventQueue();
      await subscription.cancel();
      expect(requested.map((uri) => uri.toString()), [
        'http://server:8640/api/views',
        'ws://server:8640/api/events?token=t0k',
      ]);
    });

    test('projects: list from /api/projects, per-project paths under /api/p/<id>', () async {
      final requested = <Uri>[];
      final projects = HttpProjectsApi(
        Uri.parse('http://server:8640/'),
        token: 't0k',
        client: MockClient((request) async {
          requested.add(request.url);
          final body = request.url.path == ApiPaths.projects
              ? jsonEncode([
                  const ProjectDto(id: 'kanban-ai', name: 'kanban-ai', path: '/p/kanban-ai/backlog').toJson(),
                  const ProjectDto(id: 'hobbyo', name: 'Hobbyo', path: '/p/hobbyo/backlog', error: 'missing').toJson(),
                ])
              : '[]';
          return http.Response(body, 200, headers: {'content-type': 'application/json'});
        }),
        connectSocket: (uri) {
          requested.add(uri);
          throw StateError('no socket in tests');
        },
      );
      final list = await projects.projects();
      expect(list.map((p) => p.id), ['kanban-ai', 'hobbyo']);
      expect(list.map((p) => p.isAvailable), [true, false]);
      final api = projects.project('hobbyo') as HttpBacklogApi;
      await api.views();
      await api.lint();
      final subscription = api.changes().listen(null);
      await pumpEventQueue();
      await subscription.cancel();
      expect(requested.map((uri) => uri.toString()), [
        'http://server:8640/api/projects',
        'http://server:8640/api/p/hobbyo/views',
        'http://server:8640/api/p/hobbyo/lint',
        'ws://server:8640/api/p/hobbyo/events?token=t0k',
      ]);
    });

    test('projects: PATCH /api/projects/<id> pins a project', () async {
      late http.Request sent;
      final projects = HttpProjectsApi(
        Uri.parse('http://server:8640/'),
        client: MockClient((request) async {
          sent = request;
          final body = const ProjectDto(id: 'hobbyo', name: 'Hobbyo', path: '/p/hobbyo/backlog', pinned: true).toJson();
          return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
        }),
      );
      final pinned = await projects.setPinned('hobbyo', true);
      expect(pinned.pinned, isTrue);
      expect((sent.method, sent.url.path), ('PATCH', '/api/projects/hobbyo'));
      expect(jsonDecode(sent.body), {'pinned': true});
      expect(ProjectDto.fromJson(pinned.toJson()).pinned, isTrue);
      expect(
        ProjectDto.fromJson(const {'id': 'a', 'name': 'a', 'path': '/a'}).pinned,
        isFalse,
        reason: 'older servers',
      );
    });
  });
}
