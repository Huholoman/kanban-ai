import 'dart:convert';

import 'package:backlog_api/backlog_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('DTOs survive a JSON round trip', () {
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
      blocked: true,
      blockedBy: const ['T-2'],
      children: const Progress(1, 3),
      checklist: const Progress(2, 5),
      claim: claim,
      path: 'items/T-1-backups.md',
      body: '# Body',
    );

    T roundTrip<T>(Json json, T Function(Json) decode) => decode(jsonDecode(jsonEncode(json)) as Json);

    test('item', () {
      final copy = roundTrip(item.toJson(), ItemDto.fromJson);
      expect(copy.toJson(), item.toJson());
      expect(copy.children.toString(), '1/3');
      expect(copy.isClaimed, isTrue);
    });

    test('detail, view and workflow', () {
      final detail = ItemDetailDto(
        item: item,
        parent: const ItemLinkDto(id: 'T-0', title: 'Epic', status: 'todo', category: StatusCategoryDto.open),
        dependencies: const [ItemLinkDto(id: 'T-9')],
      );
      final detailCopy = roundTrip(detail.toJson(), ItemDetailDto.fromJson);
      expect(detailCopy.toJson(), detail.toJson());
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
  });
}
