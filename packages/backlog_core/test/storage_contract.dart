import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Opens another storage over the same backlog, as another process would.
typedef OpenStorage = BacklogStorage Function();

/// The contract of [BacklogStorage] (see its documentation), for every
/// implementation: `storageContract('my storage', prepare)`, where [prepare]
/// prepares a fresh, empty backlog with the default workflow of
/// `Backlog.init` (prefix `T`) and returns how to open it. With [files] the
/// locations are files that people edit by hand ([ItemRepository.locationOf],
/// [WorkflowSource.location]), and their format is checked too.
void storageContract(String name, Future<OpenStorage> Function() prepare, {bool files = false}) {
  group('$name storage contract', () {
    late OpenStorage open;
    late Workflow workflow;

    setUp(() async {
      open = await prepare();
      workflow = (await open().configuration.load()).workflow;
    });

    BacklogStores stores() => open().stores(workflow);

    group('configuration', () {
      test('a load gives the workflow and the current revision', () async {
        final storage = open();
        final loaded = await storage.configuration.load();
        expect(loaded.workflow.idPrefix, 'T');
        expect(await storage.configuration.revision(), loaded.revision);
        expect(await open().configuration.revision(), loaded.revision);
      });

      test('an edit is seen by every storage and changes the revision', () async {
        final before = await open().configuration.revision();
        final after = await open().configuration.edit([
          const WorkflowEdit.set(['claims', 'lease_minutes'], 30),
        ]);
        expect(after, isNot(before));
        final loaded = await open().configuration.load();
        expect(loaded.revision, after);
        expect(loaded.workflow.claimLease, const Duration(minutes: 30));
      });

      test('an edit against an old revision fails and writes nothing', () async {
        final old = await open().configuration.revision();
        final current = await open().configuration.edit([
          const WorkflowEdit.set(['id', 'length'], 6),
        ]);
        await expectLater(
          open().configuration.edit([
            const WorkflowEdit.set(['id', 'length'], 8),
          ], expected: old),
          throwsA(isA<UnavailableException>()),
        );
        expect(await open().configuration.revision(), current);
        expect((await open().configuration.load()).workflow.idLength, 6);
      });

      test('an edit that makes the workflow invalid fails and writes nothing', () async {
        final before = await open().configuration.revision();
        await expectLater(
          open().configuration.edit([
            const WorkflowEdit.set(['claims', 'lease_minutes'], 'soon'),
          ]),
          throwsA(isA<ConfigurationException>()),
        );
        expect(await open().configuration.revision(), before);
      });
    });

    group('items', () {
      test('a new backlog has no items', () async {
        final catalog = await stores().items.load();
        expect(catalog.items, isEmpty);
        expect(catalog.problems, isEmpty);
      });

      test('a saved item is seen by every storage, cached or not', () async {
        final reader = stores().items;
        expect((await reader.load()).items, isEmpty);
        final saved = _item('T-0001', labels: ['infra'], body: '## Context\n\nSaved once.');
        await stores().items.save(saved);

        for (final items in [reader, stores().items]) {
          final loaded = (await items.load()).items.single;
          _expectSame(loaded, saved);
          expect(await items.locationOf(saved.id), isNotNull);
        }
        expect(await stores().items.locationOf(ItemId('T-0404')), isNull);
      });

      test('saving again replaces the item, also in a storage that read it before', () async {
        final reader = stores().items;
        await stores().items.save(_item('T-0001'));
        expect((await reader.load()).items.single.status, 'todo');

        await stores().items.save(_item('T-0001', status: 'in-progress', body: 'Changed.'));
        for (final items in [reader, stores().items]) {
          final loaded = (await items.load()).items.single;
          expect(loaded.status, 'in-progress');
          expect(loaded.body.trim(), 'Changed.');
        }
      });

      test('a save changes only its item', () async {
        final items = stores().items;
        await items.save(_item('T-0001', title: 'First'));
        await items.save(_item('T-0002', title: 'Second'));
        await stores().items.save(_item('T-0002', title: 'Second', status: 'done'));

        final loaded = {for (final item in (await stores().items.load()).items) item.id.value: item};
        expect(loaded.keys, unorderedEquals(['T-0001', 'T-0002']));
        _expectSame(loaded['T-0001']!, _item('T-0001', title: 'First'));
        expect(loaded['T-0002']!.status, 'done');
      });

      test('concurrent saves of different items are all kept', () async {
        final ids = [for (var n = 1; n <= 20; n++) 'T-${n.toString().padLeft(4, '0')}'];
        await Future.wait([for (final id in ids) stores().items.save(_item(id, title: 'Item $id'))]);

        final loaded = (await stores().items.load()).items;
        expect(loaded.map((item) => item.id.value), unorderedEquals(ids));
        for (final item in loaded) {
          expect(item.title, 'Item ${item.id}');
        }
      });

      test('a reader never sees half a write', () async {
        final long = List.filled(2000, 'A long line of the body.').join('\n');
        await stores().items.save(_item('T-0001', body: long));
        final reader = stores().items;
        final writes = Future.wait([
          for (var n = 0; n < 10; n++)
            stores().items.save(_item('T-0001', status: n.isEven ? 'todo' : 'done', body: long)),
        ]);
        for (var n = 0; n < 10; n++) {
          final catalog = await reader.load();
          expect(catalog.problems, isEmpty);
          expect(catalog.items.single.body.trim(), long);
        }
        await writes;
      });
    });

    group('claims', () {
      Claim claim(String agent, {DateTime? at, Duration lease = const Duration(hours: 1)}) {
        final time = at ?? DateTime.utc(2026, 11, 1, 12);
        return Claim(itemId: ItemId('T-0001'), agent: agent, claimedAt: time, heartbeatAt: time, lease: lease);
      }

      test('acquire, find, refresh and remove are seen by every storage', () async {
        expect(await stores().claims.tryAcquire(claim('one')), isTrue);
        expect((await stores().claims.find(ItemId('T-0001')))?.agent, 'one');
        expect((await stores().claims.all()).map((c) => c.agent), ['one']);
        expect(await stores().claims.find(ItemId('T-0002')), isNull);

        final beat = DateTime.utc(2026, 11, 1, 13);
        await stores().claims.refresh(claim('one').heartbeat(beat));
        expect((await stores().claims.find(ItemId('T-0001')))?.heartbeatAt, beat);

        await stores().claims.remove(ItemId('T-0001'));
        expect(await stores().claims.find(ItemId('T-0001')), isNull);
        expect(await stores().claims.all(), isEmpty);
      });

      test('an item has at most one claim', () async {
        expect(await stores().claims.tryAcquire(claim('one')), isTrue);
        expect(await stores().claims.tryAcquire(claim('two')), isFalse);
        expect((await stores().claims.find(ItemId('T-0001')))?.agent, 'one');
      });

      test('of agents racing for an item exactly one wins', () async {
        final agents = [for (var n = 0; n < 12; n++) 'agent-$n'];
        final won = await Future.wait([for (final agent in agents) stores().claims.tryAcquire(claim(agent))]);
        expect(won.where((ok) => ok), hasLength(1));
        final holder = (await stores().claims.find(ItemId('T-0001')))!.agent;
        expect(holder, agents[won.indexOf(true)]);
      });

      test('of agents racing to take over an expired claim exactly one wins', () async {
        final expired = claim('gone', at: DateTime.utc(2026), lease: const Duration(minutes: 1));
        expect(await stores().claims.tryAcquire(expired), isTrue);
        final agents = [for (var n = 0; n < 12; n++) 'agent-$n'];
        final won = await Future.wait([for (final agent in agents) stores().claims.tryReplace(expired, claim(agent))]);
        expect(won.where((ok) => ok), hasLength(1));
        expect((await stores().claims.find(ItemId('T-0001')))!.agent, agents[won.indexOf(true)]);
      });

      test('a claim that is no longer the expired one is not replaced', () async {
        final expired = claim('gone', at: DateTime.utc(2026), lease: const Duration(minutes: 1));
        expect(await stores().claims.tryAcquire(expired), isTrue);
        expect(await stores().claims.tryReplace(expired, claim('one')), isTrue);
        expect(await stores().claims.tryReplace(expired, claim('two')), isFalse);
        expect((await stores().claims.find(ItemId('T-0001')))!.agent, 'one');
      });
    });

    group('views', () {
      const definition = {'name': 'Mine', 'layout': 'kanban', 'group_by': 'status'};

      test('a created view gets a unique id and is seen by every storage', () async {
        final first = await stores().views.create('mine', definition);
        final second = await stores().views.create('mine', definition);
        expect(second, isNot(first));
        final views = (await stores().views.load()).views.map((view) => view.id);
        expect(views, containsAll([first, second]));
        expect(await stores().views.raw(first), definition);
      });

      test('section, pinning and columns change only what they name', () async {
        final id = await stores().views.create('mine', definition);
        await stores().views.setSection(id, 'Team');
        await stores().views.setPinned(id, true);
        await stores().views.setColumns(id, ['todo', 'done']);

        final view = (await stores().views.load()).views.singleWhere((view) => view.id == id);
        expect(
          [view.name, view.section, view.pinned, view.columns],
          [
            'Mine',
            'Team',
            true,
            ['todo', 'done'],
          ],
        );
        expect(await stores().views.raw(id), {
          ...definition,
          'section': 'Team',
          'pinned': true,
          'columns': ['todo', 'done'],
        });

        await stores().views.setSection(id, null);
        await stores().views.setPinned(id, false);
        await stores().views.setColumns(id, null);
        expect(await stores().views.raw(id), definition);
      });

      test('an unknown view is not found', () async {
        await expectLater(stores().views.setPinned('nope', true), throwsA(isA<NotFoundException>()));
      });
    });

    group('action requests', () {
      ActionRequest request(String action, int minute) =>
          ActionRequest(item: 'T-0001', action: action, at: DateTime.utc(2026, 11, 1, 12, minute), by: 'me');

      test('are taken oldest first by any storage', () async {
        await open().actionRequests.add(request('second', 2));
        await open().actionRequests.add(request('first', 1));
        final taken = await open().actionRequests.take();
        expect(taken.map((r) => (r.action, r.item, r.by)), [('first', 'T-0001', 'me'), ('second', 'T-0001', 'me')]);
        expect(await open().actionRequests.take(), isEmpty);
      });

      test('each is taken exactly once, also when storages take at the same time', () async {
        for (var n = 0; n < 10; n++) {
          await open().actionRequests.add(request('run-$n', n));
        }
        final taken = await Future.wait([for (var n = 0; n < 4; n++) open().actionRequests.take()]);
        expect(
          taken.expand((requests) => requests).map((r) => r.action),
          unorderedEquals([for (var n = 0; n < 10; n++) 'run-$n']),
        );
      });
    });

    group('changes reported', () {
      late ChangeSource source;
      final seen = <StorageChange>[];

      setUp(() async {
        seen.clear();
        source = open().watch(debounce: const Duration(milliseconds: 20));
        source.changes.listen(seen.add);
        await source.start();
      });

      tearDown(() => source.close());

      /// Waits until a reported change satisfies [test].
      Future<StorageChange> reported(bool Function(StorageChange change) test) async {
        for (var n = 0; n < 200; n++) {
          final match = seen.where(test).firstOrNull;
          if (match != null) return match;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        fail('No change reported; seen: ${[for (final change in seen) change.paths]}');
      }

      test('writes of items, claims, views and action requests by other storages', () async {
        await stores().items.save(_item('T-0001'));
        final item = await reported((change) => change.paths.isNotEmpty && !change.configuration);
        expect(item.paths, everyElement(isNot(contains('.tmp'))));

        seen.clear();
        final now = DateTime.utc(2026, 11, 1, 12);
        await stores().claims.tryAcquire(
          Claim(
            itemId: ItemId('T-0001'),
            agent: 'one',
            claimedAt: now,
            heartbeatAt: now,
            lease: const Duration(hours: 1),
          ),
        );
        await reported((change) => change.paths.isNotEmpty);

        seen.clear();
        await stores().views.create('mine', const {'name': 'Mine', 'layout': 'list'});
        await reported((change) => change.paths.isNotEmpty);

        seen.clear();
        await open().actionRequests.add(ActionRequest(item: 'T-0001', action: 'check', at: now));
        await reported((change) => change.paths.isNotEmpty);
      });

      test('configuration edits are marked as such', () async {
        await open().configuration.edit([
          const WorkflowEdit.set(['claims', 'lease_minutes'], 30),
        ]);
        await reported((change) => change.configuration);
      });

      test('nothing is reported after close', () async {
        await source.close();
        await stores().items.save(_item('T-0001'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(seen, isEmpty);
      });
    });

    if (files) {
      group('format kept', () {
        test('a save keeps comments, key order and unknown keys of the item file', () async {
          await stores().items.save(_item('T-0001'));
          final path = (await stores().items.locationOf(ItemId('T-0001')))!;
          final text = File(path).readAsStringSync();
          final edited = text.replaceFirst(
            'title:',
            '# Written by hand, must survive.\nreviewer: someone   # unknown key\ntitle:',
          );
          File(path).writeAsStringSync(edited);

          final loaded = (await stores().items.load()).items.single;
          await stores().items.save(loaded.copyWith(status: 'done'));
          final after = File(path).readAsStringSync();
          expect(after, contains('# Written by hand, must survive.\nreviewer: someone   # unknown key\ntitle:'));
          expect(after, contains('status: done'));
          expect(after.indexOf('id:'), lessThan(after.indexOf('reviewer:')));
        });

        test('a view edit keeps comments and unknown keys of the view file', () async {
          final id = await stores().views.create('mine', const {'name': 'Mine', 'layout': 'list'});
          final path = p.join(p.dirname(open().configuration.location), 'views', '$id.yaml');
          File(path).writeAsStringSync('# Kept.\n${File(path).readAsStringSync()}mine: {keep: true}\n');
          await stores().views.setPinned(id, true);
          final text = File(path).readAsStringSync();
          expect(text, startsWith('# Kept.\n'));
          expect(text, contains('mine: {keep: true}'));
          expect(text, contains('pinned: true'));
        });

        test('an edit keeps comments and unknown keys of the configuration', () async {
          final path = open().configuration.location;
          File(path).writeAsStringSync('${File(path).readAsStringSync()}\n# Kept.\nmine: {keep: true}\n');
          await open().configuration.edit([
            const WorkflowEdit.set(['claims', 'lease_minutes'], 30),
          ]);
          final text = File(path).readAsStringSync();
          expect(text, contains('# Kept.\nmine: {keep: true}\n'));
          expect(text, contains('lease_minutes: 30'));
        });
      });
    }
  });
}

Item _item(String id, {String? title, String status = 'todo', List<String> labels = const [], String body = ''}) =>
    Item(
      id: ItemId(id),
      title: title ?? 'Item $id',
      type: 'task',
      status: status,
      priority: 'p2',
      labels: labels,
      created: '2026-11-01T12:00:00Z',
      body: body,
    );

void _expectSame(Item actual, Item expected) {
  expect(
    [actual.id, actual.title, actual.type, actual.status, actual.priority, actual.labels, actual.created],
    [expected.id, expected.title, expected.type, expected.status, expected.priority, expected.labels, expected.created],
  );
  expect(actual.body.trim(), expected.body.trim());
}
