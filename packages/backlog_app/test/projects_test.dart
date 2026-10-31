import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_app/app/backlog_app.dart';
import 'package:backlog_app/features/projects/application/project_memory.dart';
import 'package:backlog_app/features/projects/application/project_route.dart';
import 'package:backlog_app/features/projects/application/projects_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

void main() {
  FakeProjectsApi threeProjects({bool brokenFirst = false}) => FakeProjectsApi(
    {
      'a': FakeBacklogApi([item('A-1')]),
      'b': FakeBacklogApi([item('B-1')]),
      'c': FakeBacklogApi([item('C-1')]),
    },
    list: [
      fakeProject('a', error: brokenFirst ? 'No backlog.yaml in /srv/a/backlog.' : null),
      fakeProject('b'),
      fakeProject('c'),
    ],
  );

  group('ProjectRoute', () {
    test('names a project as /p/<id>', () {
      expect(ProjectRoute.of('kanban-ai'), '/p/kanban-ai');
      expect(ProjectRoute.parse('/p/kanban-ai'), 'kanban-ai');
      expect(ProjectRoute.parse(ProjectRoute.of('a b')), 'a b');
      expect(ProjectRoute.parse('/'), isNull);
      expect(ProjectRoute.parse('/p/'), isNull);
      expect(ProjectRoute.parse('/x/a'), isNull);
    });
  });

  group('ProjectsController', () {
    test('opens the project from the URL and remembers it', () async {
      final api = threeProjects();
      final memory = InMemoryProjectMemory('c');
      final projects = ProjectsController(api, memory: memory, requested: 'b');
      await projects.start();
      expect(projects.current!.id, 'b');
      expect(projects.api, same(api.backlogs['b']));
      expect(memory.read(), 'b');
      expect(projects.single, isFalse);
    });

    test('without a project in the URL opens the last one, else the first available', () async {
      final remembered = ProjectsController(threeProjects(), memory: InMemoryProjectMemory('c'));
      await remembered.start();
      expect(remembered.current!.id, 'c');

      final fresh = ProjectsController(threeProjects());
      await fresh.start();
      expect(fresh.current!.id, 'a');

      final broken = ProjectsController(threeProjects(brokenFirst: true), memory: InMemoryProjectMemory('gone'));
      await broken.start();
      expect(broken.current!.id, 'b', reason: 'the first project cannot be opened, the remembered one is gone');
    });

    test('an unknown or unavailable project in the URL falls back to the default', () async {
      final unknown = ProjectsController(threeProjects(), requested: 'nope');
      await unknown.start();
      expect(unknown.current!.id, 'a');

      final unavailable = ProjectsController(threeProjects(brokenFirst: true), requested: 'a');
      await unavailable.start();
      expect(unavailable.current!.id, 'b');
    });

    test('select swaps the API; unavailable and unknown projects are ignored', () async {
      final api = threeProjects(brokenFirst: true);
      final memory = InMemoryProjectMemory();
      final projects = ProjectsController(api, memory: memory);
      await projects.start();
      var notified = 0;
      projects.addListener(() => notified++);

      projects.select('c');
      expect(projects.current!.id, 'c');
      expect(projects.api, same(api.backlogs['c']));
      expect(memory.read(), 'c');
      projects.select('a');
      projects.select('nope');
      projects.select('c');
      expect(projects.current!.id, 'c');
      expect(notified, 1);
    });

    test('a server without projects (404) falls back to the single backlog', () async {
      final single = FakeBacklogApi([item('T-1')]);
      final api = FakeProjectsApi({}, failure: const BacklogApiException(404, 'not_found', 'No such endpoint.'));
      final projects = ProjectsController(api, fallback: single);
      await projects.start();
      expect(projects.api, same(single));
      expect(projects.single, isTrue);
      expect(projects.current, isNull);
      expect(projects.projects, isEmpty);
    });

    test('other failures are reported and can be retried', () async {
      final api = threeProjects()..failure = const BacklogApiException(401, 'unauthorized', 'Token required.');
      final projects = ProjectsController(api, fallback: FakeBacklogApi([]));
      await projects.start();
      expect(projects.api, isNull);
      expect(projects.error, isA<BacklogApiException>());

      api.failure = null;
      await projects.start();
      expect(projects.error, isNull);
      expect(projects.current!.id, 'a');
    });

    test('nothing opens when no project is available', () async {
      final api = FakeProjectsApi({}, list: [fakeProject('a', error: 'Missing folder.')]);
      final projects = ProjectsController(api);
      await projects.start();
      expect(projects.loading, isFalse);
      expect(projects.api, isNull);
      expect(projects.projects, hasLength(1));
    });
  });

  group('BacklogApp with projects', () {
    late List<String> announced;

    Future<void> pumpApp(
      WidgetTester tester, {
      ProjectsApi? projects,
      BacklogApi? api,
      String? route,
      ProjectMemory? memory,
      double width = 1400,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      announced = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.navigation, (call) async {
        if (call.method == 'routeInformationUpdated') announced.add((call.arguments as Map)['uri'] as String);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.navigation, null),
      );
      await tester.pumpWidget(BacklogApp(projects: projects, api: api, initialRoute: route, memory: memory));
      await tester.pumpAndSettle();
    }

    /// What the browser does when the URL after `#` is edited.
    Future<void> pushRoute(WidgetTester tester, String route) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec.encodeMethodCall(
          MethodCall('pushRouteInformation', {'location': route, 'state': null}),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    String title(WidgetTester tester) => tester.widget<MaterialApp>(find.byType(MaterialApp)).title ?? '';

    testWidgets('opens the project from the URL, puts it back into the URL and the page title', (tester) async {
      final api = threeProjects();
      await pumpApp(tester, projects: api, route: '/p/b');
      expect(find.text('Item B-1'), findsOneWidget);
      expect(find.text('Item A-1'), findsNothing);
      expect(announced.last, '/p/b');
      expect(title(tester), 'Project b');
    });

    testWidgets('without a project in the URL the default one is shown and named in the URL', (tester) async {
      await pumpApp(tester, projects: threeProjects(), memory: InMemoryProjectMemory());
      expect(find.text('Item A-1'), findsOneWidget);
      expect(announced.last, '/p/a');
    });

    testWidgets('another project in the URL replaces the board and drops the old live updates', (tester) async {
      final api = threeProjects();
      await pumpApp(tester, projects: api, route: '/p/a');
      final first = api.backlogs['a']!;
      expect(first.listening, isTrue);

      await pushRoute(tester, '/p/c');
      expect(find.text('Item C-1'), findsOneWidget);
      expect(find.text('Item A-1'), findsNothing);
      expect(first.listening, isFalse, reason: 'board, theme and detail of project a are disposed');
      expect(api.backlogs['c']!.listening, isTrue);
      expect(announced.last, '/p/c');
      expect(title(tester), 'Project c');

      await pushRoute(tester, '/p/nope');
      expect(find.text('Item C-1'), findsOneWidget, reason: 'unknown projects are ignored');
    });

    testWidgets('a server without projects shows its single backlog', (tester) async {
      final single = FakeBacklogApi([item('T-1')]);
      await pumpApp(
        tester,
        projects: FakeProjectsApi({}, failure: const BacklogApiException(404, 'not_found', 'No such endpoint.')),
        api: single,
        route: '/p/a',
      );
      expect(find.text('Item T-1'), findsOneWidget);
      expect(single.listening, isTrue);
      expect(title(tester), 'Backlog');
      expect(announced, isNot(contains('/p/a')));
    });

    testWidgets('when no project can be opened their errors are listed', (tester) async {
      await pumpApp(
        tester,
        projects: FakeProjectsApi({}, list: [fakeProject('a', error: 'Missing folder.')]),
      );
      expect(find.text('No project can be opened.'), findsOneWidget);
      expect(find.text('Project a: Missing folder.'), findsOneWidget);
    });

    testWidgets('a failed project list offers a retry', (tester) async {
      final api = threeProjects()..failure = const BacklogApiException(0, 'unreachable', 'Server unreachable.');
      await pumpApp(tester, projects: api);
      expect(find.text('Retry'), findsOneWidget);
      api.failure = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Item A-1'), findsOneWidget);
    });

    group('switcher', () {
      testWidgets('lists the projects: the open one ticked, a broken one with its error and disabled', (tester) async {
        await pumpApp(tester, projects: threeProjects(brokenFirst: true), route: '/p/b');
        expect(find.byKey(const ValueKey('project-name')), findsOneWidget);
        expect(find.text('Project b'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('project-switcher')));
        await tester.pumpAndSettle();
        MenuItemButton entry(String id) => tester.widget<MenuItemButton>(find.byKey(ValueKey('project-$id')));
        expect(entry('a').onPressed, isNull, reason: 'the backlog cannot be opened');
        expect(find.text('No backlog.yaml in /srv/a/backlog.'), findsOneWidget);
        expect(entry('b').onPressed, isNull, reason: 'already open');
        expect(
          find.descendant(of: find.byKey(const ValueKey('project-b')), matching: find.byIcon(Icons.check)),
          findsOneWidget,
        );
        expect(entry('c').onPressed, isNotNull);

        await tester.tap(find.byKey(const ValueKey('project-a')), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('Item B-1'), findsOneWidget, reason: 'tapping a broken project does nothing');
      });

      testWidgets('choosing a project swaps the board, closes the open item and remembers it', (tester) async {
        final api = threeProjects();
        final memory = InMemoryProjectMemory();
        await pumpApp(tester, projects: api, route: '/p/a', memory: memory);
        await tester.tap(find.text('Item A-1'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('detail-A-1')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('project-switcher')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('project-c')));
        await tester.pumpAndSettle();
        expect(find.text('Item C-1'), findsOneWidget);
        expect(find.text('Item A-1'), findsNothing);
        expect(find.byKey(const ValueKey('detail-A-1')), findsNothing);
        expect(api.backlogs['a']!.listening, isFalse);
        expect(memory.read(), 'c');
        expect(announced.last, '/p/c');
        expect(find.text('Project c'), findsOneWidget);
      });

      testWidgets('with one project the navigation shows just its name', (tester) async {
        await pumpApp(
          tester,
          projects: FakeProjectsApi({
            'solo': FakeBacklogApi([item('S-1')]),
          }),
        );
        expect(find.text('Project solo'), findsOneWidget);
        expect(find.byKey(const ValueKey('project-switcher')), findsNothing);
      });

      testWidgets('on a phone the switcher is in the drawer', (tester) async {
        await pumpApp(tester, projects: threeProjects(), route: '/p/a', width: 400);
        await tester.tap(find.byKey(const ValueKey('bottom-more')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('project-switcher')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('project-b')));
        await tester.pumpAndSettle();
        expect(find.text('Item B-1'), findsOneWidget);
        expect(find.byType(Drawer), findsNothing, reason: 'the new project starts with the drawer closed');
      });
    });
  });
}
