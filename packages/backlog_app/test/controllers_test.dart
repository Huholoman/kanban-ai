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

    test('an unreachable server is an error, not a crash', () async {
      final broken = BoardController(_UnreachableApi(api));
      addTearDown(broken.dispose);
      await broken.start();
      expect(broken.error, isA<BacklogApiException>());
      expect(broken.result, isNull);
      expect(broken.loading, isFalse);
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
      expect(appearance.theme(Brightness.dark).colorScheme.surface, const Color(0xFF101820));

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
  Future<WorkflowDto> workflow() => Future.error(const BacklogApiException(0, 'network', 'unreachable'));

  @override
  Stream<BacklogChangeEvent> changes() => _inner.changes();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
