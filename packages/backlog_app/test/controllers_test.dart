import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/appearance_controller.dart';
import 'package:backlog_app/features/board/application/board_controller.dart';
import 'package:backlog_app/features/board/application/board_filter.dart';
import 'package:backlog_app/features/item/application/item_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

void main() {
  group('BoardController', () {
    late FakeBacklogApi api;
    late BoardController board;

    setUp(() async {
      api = FakeBacklogApi([item('T-1'), item('T-2', status: 'in-progress')]);
      board = BoardController(api, refreshDelay: const Duration(milliseconds: 10));
      await board.start();
    });

    tearDown(() => board.dispose());

    test('starts on the board view and allows moving by status', () {
      expect(board.selectedViewId, 'board');
      expect(board.result!.groups.map((g) => g.key), ['todo', 'in-progress', 'done']);
      expect(board.canMove, isTrue);
      expect(board.workflow!.priorities, hasLength(4));
    });

    test('the filter narrows the visible items and survives a view switch', () async {
      board.setFilter(BoardFilter.none.withText('T-2'));
      expect(board.visible!.groups.expand((g) => g.items).map((i) => i.id), ['T-2']);
      expect(board.counts, (shown: 1, total: 2));
      await board.selectView('list');
      expect(board.filter.text, 'T-2');
      expect(board.visible!.groups.expand((g) => g.items).map((i) => i.id), ['T-2']);
    });

    test('views are grouped into sections and can be moved between them', () async {
      expect(board.viewSections.map((s) => '${s.$1}: ${s.$2.map((v) => v.id).join(',')}'), ['null: list,board']);
      await board.moveView('board', 'Planning');
      expect(api.viewSections, {'board': 'Planning'});
      expect(board.viewSections.map((s) => '${s.$1}: ${s.$2.map((v) => v.id).join(',')}'), [
        'null: list',
        'Planning: board',
      ]);
      expect(board.sectionNames, ['Planning']);
      await board.moveView('board', '');
      expect(board.sectionNames, isEmpty);
    });

    test('the view can be regrouped for the session and resets on view change', () async {
      await board.setGroupBy('priority');
      expect(board.result!.groupBy, 'priority');
      expect(board.canMove, isTrue, reason: 'dropping into a priority column sets the priority');
      await board.selectView('list');
      expect(board.groupByOverride, isNull);
    });

    test('people are the agents with live claims, busiest first', () async {
      ClaimDto claim(String agent, {bool expired = false}) => ClaimDto(
        item: 'x',
        agent: agent,
        claimedAt: DateTime.utc(2026),
        heartbeatAt: DateTime.utc(2026),
        expiresAt: DateTime.utc(2027),
        expired: expired,
      );
      ItemDto claimed(String id, ClaimDto c) =>
          ItemDto(id: id, title: id, type: 'task', status: 'in-progress', priority: 'p2', claim: c);
      board.dispose(); // the one from setUp; tearDown disposes the new one
      api = FakeBacklogApi([
        claimed('A', claim('bob')),
        claimed('B', claim('alice')),
        claimed('C', claim('alice')),
        claimed('D', claim('carol', expired: true)),
      ]);
      board = BoardController(api, refreshDelay: const Duration(milliseconds: 10));
      await board.start();
      expect(board.people, [('alice', 2), ('bob', 1)]);
      board.showPerson('bob');
      expect(board.filter.valuesFor(FilterFacet.person), {'bob'});
    });

    test('list views cannot be reordered by dragging', () async {
      await board.selectView('list');
      expect(board.result!.layout, ViewLayoutDto.list);
      expect(board.canMove, isFalse);
    });

    test('move sets the group field and refreshes', () async {
      await board.move(board.result!.groups.first.items.single, 'done');
      expect(api.updates.single.$1, 'T-1');
      expect(api.updates.single.$2.changes, ['status=done']);
      expect(board.result!.groups.last.items.map((i) => i.id), ['T-1']);
    });

    test('a failed move is reported and the board shows the real state again', () async {
      api.failNextUpdate = const BacklogApiException(400, 'invalid_input', 'nope');
      final notices = <String>[];
      board.notices.listen(notices.add);
      await board.move(board.result!.groups.first.items.single, 'done');
      await pumpEventQueue();
      expect(notices.single, contains('nope'));
      expect(board.result!.groups.first.items.map((i) => i.id), ['T-1']);
    });

    test('reloads after the backlog changed on disk', () async {
      final before = api.viewLoads;
      api.externalChange(item('T-3', status: 'todo'));
      api.externalChange(item('T-4', status: 'todo'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(api.viewLoads, before + 1, reason: 'a burst of changes causes one reload');
      expect(board.result!.groups.first.items.map((i) => i.id), containsAll(['T-3', 'T-4']));
    });

    test('reloads only what the changed paths concern', () async {
      Future<Map<String, int>> after(List<String>? paths) async {
        final before = {...api.loads};
        final views = api.viewLoads;
        paths == null ? api.dispatchChange(DispatchDto.off) : api.touched(paths);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return {
          for (final name in ['workflow', 'items', 'lint']) name: (api.loads[name] ?? 0) - (before[name] ?? 0),
          'view': api.viewLoads - views,
        };
      }

      expect(await after(['items/T-1-a.md']), {'workflow': 0, 'items': 1, 'lint': 1, 'view': 1});
      expect(await after(['views/board.yaml']), {'workflow': 0, 'items': 0, 'lint': 1, 'view': 1});
      expect(await after(['backlog.yaml']), {'workflow': 1, 'items': 1, 'lint': 1, 'view': 1});
      expect(await after(['docs/notes.md']), {'workflow': 0, 'items': 0, 'lint': 0, 'view': 0});
      expect(await after(['other.txt']), {'workflow': 1, 'items': 1, 'lint': 1, 'view': 1});
      // The plan: items carry the AI review state.
      expect(await after(null), {'workflow': 0, 'items': 1, 'lint': 0, 'view': 1});
      expect(board.lint, isEmpty);
      expect(board.workflow, isNotNull);
    });

    test('fills the view from the items by id', () async {
      final full = await api.view('board');
      final named = await api.view('board', idsOnly: true);
      expect(named.groups.first.items, isEmpty);
      expect(named.groups.first.ids, full.groups.first.ids);
      expect(board.result!.toJson(), full.toJson(), reason: 'the board asks for ids and fills them in');
    });

    test('an unreachable server is an error, not a crash', () async {
      final broken = BoardController(_UnreachableApi(api));
      addTearDown(broken.dispose);
      await broken.start();
      expect(broken.error, isA<BacklogApiException>());
      expect(broken.result, isNull);
      expect(broken.loading, isFalse);
    });

    test('refresh sends its requests at the same time; a failure keeps the shown content', () async {
      final gated = _GatedApi(api);
      final controller = BoardController(gated);
      addTearDown(controller.dispose);

      // First load: the view to show is known only from the list of views.
      final first = controller.start();
      await Future<void>.delayed(Duration.zero);
      expect(gated.requests, unorderedEquals(['workflow', 'views', 'lint', 'items']));
      gated.open();
      await Future<void>.delayed(Duration.zero);
      expect(gated.requests.last, 'view board');
      gated.open();
      await first;
      expect(controller.result!.id, 'board');

      // Later refreshes ask for the current view right away as well.
      gated.requests.clear();
      final quiet = controller.refresh(quiet: true);
      await Future<void>.delayed(Duration.zero);
      expect(gated.requests, unorderedEquals(['view board', 'workflow', 'views', 'lint', 'items']));
      expect(controller.loading, isFalse, reason: 'a quiet refresh keeps the content visible');
      gated.failViews = const BacklogApiException(500, 'internal', 'boom');
      gated.open();
      await quiet;
      expect(controller.error, isA<BacklogApiException>());
      expect(controller.result!.id, 'board', reason: 'the last good content stays');
      expect(controller.loading, isFalse);
    });

    test('a refresh that discards an older one loads the older one\'s parts too', () async {
      final gated = _GatedApi(api);
      final controller = BoardController(gated);
      addTearDown(controller.dispose);
      final first = controller.start();
      gated.open();
      await Future<void>.delayed(Duration.zero);
      gated.open();
      await first;

      gated.requests.clear();
      final older = controller.refresh(quiet: true, changed: {BacklogPart.views});
      await Future<void>.delayed(Duration.zero);
      expect(gated.requests, unorderedEquals(['view board', 'views', 'lint']));
      gated.requests.clear();
      final newer = controller.refresh(quiet: true, changed: {BacklogPart.plan});
      await Future<void>.delayed(Duration.zero);
      expect(gated.requests, unorderedEquals(['view board', 'views', 'lint', 'items']));
      gated.open();
      await Future.wait([older, newer]);

      gated.requests.clear();
      final next = controller.refresh(quiet: true, changed: {BacklogPart.plan});
      await Future<void>.delayed(Duration.zero);
      expect(gated.requests, unorderedEquals(['view board', 'items']), reason: 'loaded parts are fresh');
      gated.open();
      await next;
    });
  });

  group('ItemController', () {
    test('loads, edits fields and body and claims as the configured agent', () async {
      final api = FakeBacklogApi([item('T-1', body: 'old')]);
      final controller = ItemController(api, 'T-1', agent: 'tobik');
      addTearDown(controller.dispose);
      await controller.start();
      expect(controller.item!.body, 'old');

      expect(await controller.set('priority', 'p0'), isTrue);
      expect(controller.item!.priority, 'p0');
      expect(await controller.saveBody('new\n'), isTrue);
      expect(controller.item!.body, 'new\n');
      expect(api.updates.map((u) => u.$2.changes), [
        ['priority=p0'],
        <String>[],
      ]);

      await controller.claim();
      await controller.complete();
      expect(api.claims.map((c) => (c.$1, c.$3.agent)), [('claim', 'tobik'), ('done', 'tobik')]);
      expect(controller.item!.isDone, isTrue);
    });

    test('loads the parent chain, the siblings and previews of children', () async {
      final api = FakeBacklogApi([
        item('E-1', type: 'epic'),
        item('S-1', type: 'story', parent: 'E-1'),
        item('S-2', type: 'story', parent: 'E-1'),
        item('T-1', parent: 'S-2', body: 'first'),
      ]);
      final controller = ItemController(api, 'S-2', refreshDelay: Duration.zero);
      addTearDown(controller.dispose);
      await controller.start();
      expect(controller.ancestors.map((a) => a.item.id), ['E-1']);
      expect(controller.siblings.map((s) => s.id), ['S-1', 'S-2']);
      expect('${controller.position}', '2 / 2');

      expect(controller.preview('T-1'), isNull);
      await controller.loadPreview('T-1');
      expect(controller.preview('T-1')!.item.body, 'first');
      api.externalChange(item('T-1', parent: 'S-2', body: 'second'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.preview('T-1')!.item.body, 'second', reason: 'previews follow changes');
    });

    test('a missing item shows an error', () async {
      final controller = ItemController(FakeBacklogApi([]), 'T-9');
      addTearDown(controller.dispose);
      await controller.start();
      expect((controller.error! as BacklogApiException).type, 'not_found');
    });
  });

  group('AppearanceController', () {
    test('follows backlog.yaml, reloads on change and can be switched', () async {
      final api = FakeBacklogApi(const [])
        ..appearance = const AppearanceDto(
          mode: 'dark',
          dark: PaletteDto(background: '#101820'),
        );
      final appearance = AppearanceController(api, refreshDelay: const Duration(milliseconds: 10));
      addTearDown(appearance.dispose);
      await appearance.start();
      expect(appearance.mode, ThemeMode.dark);
      expect(appearance.theme(Brightness.dark).scaffoldBackgroundColor, const Color(0xFF101820));

      api
        ..appearance = const AppearanceDto(
          mode: 'light',
          light: PaletteDto(primary: '#ff0000'),
        )
        ..configChange();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(appearance.mode, ThemeMode.light);
      expect(appearance.theme(Brightness.light).colorScheme.primary, const Color(0xFFFF0000));

      appearance.cycleMode();
      expect(appearance.mode, ThemeMode.dark);
      appearance.cycleMode();
      expect(appearance.mode, ThemeMode.system);
    });
  });
}

final class _UnreachableApi implements BacklogApi {
  _UnreachableApi(this._inner);

  final BacklogApi _inner;

  @override
  Stream<BacklogChangeEvent> changes() => _inner.changes();

  /// Every request fails as without a network.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(const BacklogApiException(0, 'network', 'unreachable'));
}

/// Holds every answer of [_inner] until [open]; records the requests.
final class _GatedApi implements BacklogApi {
  _GatedApi(this._inner);

  final FakeBacklogApi _inner;
  final requests = <String>[];
  var _gate = Completer<void>();
  Object? failViews;

  void open() {
    _gate.complete();
    _gate = Completer<void>();
  }

  Future<T> _held<T>(String name, Future<T> Function() answer) async {
    requests.add(name);
    await _gate.future;
    return answer();
  }

  @override
  Future<WorkflowDto> workflow() => _held('workflow', _inner.workflow);

  @override
  Future<List<ViewSummaryDto>> views() =>
      _held('views', () => failViews == null ? _inner.views() : Future.error(failViews!));

  @override
  Future<List<LintIssueDto>> lint() => _held('lint', _inner.lint);

  @override
  Future<List<ItemDto>> items({bool includeDone = false}) =>
      _held('items', () => _inner.items(includeDone: includeDone));

  @override
  Future<ViewResultDto> view(String id, {String? groupBy, bool idsOnly = false}) =>
      _held('view $id', () => _inner.view(id, groupBy: groupBy, idsOnly: idsOnly));

  @override
  Stream<BacklogChangeEvent> changes() => _inner.changes();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
