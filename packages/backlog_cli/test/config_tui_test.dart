import 'dart:async';
import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:backlog_core/backlog_core.dart'
    show
        BacklogLayout,
        StatusCategory,
        ViewLayout,
        parseViewYaml,
        parseProjectRegistryYaml,
        parseServerConfigYaml,
        parseWorkflowYaml;
import 'package:dart_tui/dart_tui.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Drives the TUI model as `dart_tui`'s [Program] would: each message goes
/// to `update`, commands run and their messages follow; every frame is kept
/// without styling.
final class Driver {
  Driver(this.input);

  final List<Msg> input;
  final frames = <List<String>>[];
  var quit = false;

  Future<void> run(Model app) async {
    Model model = app;
    Future<void> apply(Msg msg) async {
      final (next, cmd) = model.update(msg);
      model = next;
      frames.add([for (final line in (model as dynamic).lines() as List<String>) _plain(line)]);
      if (cmd == null) return;
      final result = await cmd();
      if (result is QuitMsg) {
        quit = true;
      } else if (result != null) {
        await apply(result);
      }
    }

    await apply(WindowSizeMsg(100, 30));
    for (final msg in input) {
      if (quit) break;
      await apply(msg);
    }
  }

  String get last => frames.last.join('\n');

  bool showed(String text) => frames.any((frame) => frame.join('\n').contains(text));
}

/// [chunks] with a pause before each, as typed by a person: opening a
/// screen reads files asynchronously.
Stream<List<int>> _slowly(List<List<int>> chunks) async* {
  for (final chunk in chunks) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    yield chunk;
  }
}

/// Swallows the terminal output of a [Program] under test.
final class _Discard implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}
}

String _plain(String line) => line.replaceAll(RegExp(r'\x1b\[[0-9;?:]*[A-Za-z]'), '');

Msg key(KeyCode code) => KeyPressMsg(TeaKey(code: code));

Msg char(String text) => KeyPressMsg(TeaKey(code: KeyCode.rune, text: text));

List<Msg> type(String text) => [for (final c in text.split('')) char(c)];

final enter = key(KeyCode.enter);
final up = key(KeyCode.up);
final down = key(KeyCode.down);
final end = key(KeyCode.end);
final backspace = key(KeyCode.backspace);
final ctrlC = KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'c', modifiers: {KeyMod.ctrl}));

void main() {
  late Directory workspace;
  late String backlogDir;

  Future<(int, String)> run(List<String> args, Driver? driver, {Map<String, String> env = const {}}) async {
    final err = StringBuffer();
    final code = await runBacklogCli(
      args,
      CliContext(out: StringBuffer(), err: err, cwd: workspace.path, environment: env, runTui: driver?.run),
    );
    return (code, err.toString());
  }

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('backlog_tui_');
    backlogDir = p.join(workspace.path, 'backlog');
    expect((await run(['init', 'backlog', '--prefix', 'HB', '--no-register'], null)).$1, 0);
  });

  tearDown(() => workspace.delete(recursive: true));

  File config() => File(p.join(backlogDir, BacklogLayout.configFileName));

  // Root → Project → This folder → Edit a value (second to last entry).
  final openValueEditor = [down, enter, enter, end, up, enter];

  test('edits a value of backlog.yaml, shows the diff and saves after confirmation', () async {
    final driver = Driver([
      ...openValueEditor,
      ...type('claims.lease_minutes'),
      enter,
      backspace, backspace, backspace, ...type('60'), enter, // the value was 240
      end, enter, // Review and save
      char('y'),
      char('q'),
    ]);
    final (code, err) = await run(['config'], driver);
    expect(code, 0, reason: err);
    expect(driver.showed('backlog config › Project › ${p.basename(workspace.path)}'), isTrue);
    expect(driver.showed('statuses, priorities, types, milestones'), isTrue);
    expect(driver.showed('> 240'), isTrue);
    expect(driver.showed('-  lease_minutes: 240'), isTrue);
    expect(driver.showed('+  lease_minutes: 60'), isTrue);
    expect(driver.showed('Valid. Save?'), isTrue);
    expect(driver.showed('Saved ${config().path}.'), isTrue);
    expect(
      config().readAsStringSync(),
      contains('  lease_minutes: 60   # a claim without heartbeat expires after this'),
    );
    expect(config().readAsStringSync(), contains('# Backlog configuration.'));
  });

  test('an invalid draft cannot be saved and leaving asks about unsaved changes', () async {
    final before = config().readAsStringSync();
    final driver = Driver([
      ...openValueEditor,
      ...type('claims.lease_minutes'),
      enter,
      backspace, backspace, backspace, ...type('soon'), enter,
      end, enter,
      char('y'), // refused
      char('n'),
      char('q'),
      char('y'), // discard and leave the project
    ]);
    final (code, err) = await run(['config'], driver);
    expect(code, 0, reason: err);
    expect(driver.showed('Cannot save: '), isTrue);
    expect(driver.showed('claims.lease_minutes must be an integer'), isTrue);
    expect(driver.showed('Unsaved changes (2 changed lines).'), isTrue);
    expect(driver.showed('without saving 2 changed lines?'), isTrue);
    expect(driver.frames.last.first, 'backlog config › Project');
    expect(config().readAsStringSync(), before);
  });

  // Root → Project → This folder → Workflow.
  final openWorkflow = [down, enter, enter, enter];

  test('renames a status on the workflow page and saves it', () async {
    final driver = Driver([
      ...openWorkflow,
      enter, // Statuses
      down, down, enter, // in-progress
      enter, // Rename…
      for (var i = 0; i < 'in-progress'.length; i++) backspace,
      ...type('doing'), enter,
      key(KeyCode.escape), key(KeyCode.escape), // back to Workflow
      end, enter, // Review and save
      char('y'),
      char('q'),
    ]);
    final (code, err) = await run(['config'], driver);
    expect(code, 0, reason: err);
    expect(
      driver.showed('backlog config › Project › ${p.basename(workspace.path)} › Workflow › Statuses › in-progress'),
      isTrue,
    );
    expect(driver.showed('backlog, todo, in-progress, review, done, cancelled'), isTrue);
    expect(driver.showed('Renamed in-progress to doing (not saved yet).'), isTrue);
    expect(driver.showed('+  - id: doing'), isTrue);
    expect(driver.showed('Saved ${config().path}.'), isTrue);
    final saved = config().readAsStringSync();
    expect(saved, contains('  - id: doing\n'));
    expect(saved, isNot(contains('- id: in-progress')));
    expect(saved, contains('# Backlog configuration.'));
  });

  test('adds and moves statuses, sets a default and the claim lease', () async {
    final driver = Driver([
      ...openWorkflow,
      enter, // Statuses
      end, up, enter, // Add a status…
      ...type('deploy'), enter,
      down, enter, // active
      key(KeyCode.home), down, enter, // todo
      down, down, down, enter, // Move up
      key(KeyCode.escape), key(KeyCode.escape), // back to Workflow
      down, down, down, down, enter, // Defaults
      down, enter, // Priority
      down, enter, // p1
      key(KeyCode.escape),
      end, up, enter, // Claim lease
      backspace, backspace, backspace, ...type('30'), enter,
      end, enter, // Review and save
      char('y'),
      char('q'),
    ]);
    final (code, err) = await run(['config'], driver);
    expect(code, 0, reason: err);
    expect(driver.showed('Added status deploy (not saved yet).'), isTrue);
    expect(driver.showed('Moved todo to position 1 (not saved yet).'), isTrue);
    expect(driver.showed('Default priority: p1 (not saved yet).'), isTrue);
    expect(driver.showed('Saved ${config().path}.'), isTrue, reason: driver.last);
    final workflow = parseWorkflowYaml(config().readAsStringSync());
    expect(workflow.statuses.map((s) => s.id), [
      'todo',
      'backlog',
      'in-progress',
      'review',
      'deploy',
      'done',
      'cancelled',
    ]);
    expect(workflow.categoryOf('deploy'), StatusCategory.active);
    expect(workflow.defaultPriority, 'p1');
    expect(workflow.claimLease, const Duration(minutes: 30));
  });

  test('an invalid edit says why and changes nothing', () async {
    final driver = Driver([
      ...openWorkflow,
      end, up, enter, // Claim lease
      backspace, backspace, backspace, ...type('soon'), enter,
      ctrlC,
    ]);
    final (code, err) = await run(['config'], driver);
    expect(code, 0, reason: err);
    expect(driver.last, contains('"soon" is not a whole number.'));
    expect(driver.last, contains('240 minutes'));
  });

  test('the server settings: port and a generated token', () async {
    final server = p.join(workspace.path, 'server.yaml');
    final driver = Driver([
      enter, down, enter, // Global → Server
      down, enter, ...type('8642'), enter, // Port
      down, down, enter, // Token
      enter, // Generate a new token
      key(KeyCode.escape),
      end, enter, // Review and save
      char('y'),
      ctrlC,
    ]);
    final (code, err) = await run(
      ['config', '--projects', p.join(workspace.path, 'projects.yaml')],
      driver,
      env: {'BACKLOG_SERVER_CONFIG': server},
    );
    expect(code, 0, reason: err);
    expect(driver.showed('backlog config › Global › Server'), isTrue);
    expect(driver.showed('8640 (the default)'), isTrue);
    expect(driver.showed('Port set (not saved yet).'), isTrue);
    expect(driver.showed('Saved $server.'), isTrue, reason: driver.last);
    final config = parseServerConfigYaml(File(server).readAsStringSync(), baseDir: workspace.path);
    expect(config.port, 8642);
    expect(config.token, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    expect(driver.showed('Token: ${config.token}'), isTrue);
  });

  // Root → Project → This folder, then the n-th entry after Workflow.
  List<Msg> openProjectEntry(int n) => [down, enter, enter, for (var i = 0; i < n; i++) down, enter];

  test('adds a view and sets its section', () async {
    final driver = Driver([
      ...openProjectEntry(1), // Views
      end, enter, ...type('v03'), enter, // Add a view…
      down, enter, ...type('Milestones'), enter, // Section
      end, enter, char('y'), // Review and save
      key(KeyCode.escape), // back to Views
      ctrlC,
    ]);
    final (code, err) = await run(['config'], driver);
    expect(code, 0, reason: err);
    expect(driver.showed('backlog config › Project › ${p.basename(workspace.path)} › Views › v03'), isTrue);
    expect(driver.showed('New view v03 (not saved yet).'), isTrue);
    final file = File(p.join(backlogDir, 'views', 'v03.yaml'));
    expect(driver.showed('Saved ${file.path}.'), isTrue, reason: driver.last);
    final view = parseViewYaml('v03', file.readAsStringSync());
    expect((view.name, view.section, view.layout, view.groupBy), ('v03', 'Milestones', ViewLayout.kanban, 'status'));
    expect(driver.last, contains('v03 · kanban · Milestones'));
  });

  test('releases a claim and fixes a lint issue', () async {
    expect((await run(['new', 'Claimed', '-s', 'todo'], null)).$1, 0);
    expect((await run(['next', '--as', 'w1'], null)).$1, 0);
    expect((await run(['new', 'Broken'], null)).$1, 0);
    final broken = Directory(
      p.join(backlogDir, 'items'),
    ).listSync().whereType<File>().firstWhere((f) => f.readAsStringSync().contains('Broken'));
    broken.writeAsStringSync(broken.readAsStringSync().replaceFirst('status: backlog', 'status: doing'));

    final driver = Driver([
      ...openProjectEntry(2), // Claims
      enter, enter, // the claim → Release
      key(KeyCode.escape),
      down, enter, // Lint
      enter, enter, // the issue → Set status to backlog
      ctrlC,
    ]);
    final (code, err) = await run(['config'], driver);
    expect(code, 0, reason: err);
    expect(driver.showed('HB-'), isTrue);
    expect(driver.showed('w1'), isTrue);
    expect(driver.showed('Released HB-'), isTrue, reason: driver.frames.map((f) => f.join('\n')).join('\n----\n'));
    expect(driver.showed('Unknown status "doing".'), isTrue);
    expect(driver.showed('Set status to backlog: done.'), isTrue, reason: driver.last);
    expect(driver.last, contains('No problems found.'));
    expect(broken.readAsStringSync(), contains('status: backlog'));
  });

  test('colours a status and sets the mode on the appearance page', () async {
    final driver = Driver([
      ...openProjectEntry(4), // Appearance
      down, down, down, enter, // Status colours
      down, down, enter, ...type('#FB8C00'), enter, // in-progress
      key(KeyCode.escape),
      key(KeyCode.home), enter, down, down, enter, // Mode → dark
      end, enter, char('y'), // Review and save
      ctrlC,
    ]);
    final (code, err) = await run(['config'], driver);
    expect(code, 0, reason: err);
    expect(driver.showed('status in-progress      #fb8c00 (not saved yet).'), isTrue);
    expect(driver.showed('Status: in-progress'), isTrue);
    expect(driver.showed('Mode dark (not saved yet).'), isTrue);
    expect(driver.showed('Saved ${config().path}.'), isTrue, reason: driver.last);
    final appearance = parseWorkflowYaml(config().readAsStringSync()).appearance;
    expect(appearance.mode, 'dark');
    expect(appearance.statuses, {'in-progress': '#fb8c00'});
  });

  test('adds a dispatcher worktree, checks it and previews the command', () async {
    final driver = Driver([
      ...openProjectEntry(5), // Dispatcher
      down, down, enter, // Worktrees
      enter, ...type('w1'), enter, enter, // Add a worktree… → w1 in ../w1
      key(KeyCode.escape),
      end, up, enter, // Command preview
      key(KeyCode.escape),
      end, enter, char('y'), // Review and save
      ctrlC,
    ]);
    final (code, err) = await run(['config'], driver);
    expect(code, 0, reason: err);
    expect(driver.showed('No dispatcher yet'), isTrue);
    expect(driver.showed('Added worktree w1 (not saved yet).'), isTrue);
    expect(driver.showed('w1: ${p.join(workspace.path, 'w1')} does not exist'), isTrue);
    expect(driver.showed('{id} = HB-7f3a'), isTrue);
    expect(driver.showed('claude -p '), isTrue);
    expect(driver.showed('Saved ${config().path}.'), isTrue, reason: driver.last);
    expect(parseWorkflowYaml(config().readAsStringSync()).dispatcher!.worktrees.single.name, 'w1');
  });

  test('the global part shows the project registry', () async {
    final registry = p.join(workspace.path, 'projects.yaml');
    File(registry).writeAsStringSync('projects:\n  - id: hb\n    name: Hobby\n    path: backlog\n    pinned: true\n');
    final driver = Driver([enter, enter, ctrlC]);
    final (code, err) = await run(['config', '--projects', registry], driver);
    expect(code, 0, reason: err);
    expect(driver.last, contains('backlog config › Global › Projects'));
    expect(driver.last, contains('Hobby  $backlogDir  default  pinned  opens'));
    expect(driver.quit, isTrue);
  });

  test('the registry page adds a project, makes it the default and saves', () async {
    final registry = p.join(workspace.path, 'projects.yaml');
    File(registry).writeAsStringSync('# mine\nprojects:\n  - id: hb\n    path: backlog\n');
    final driver = Driver([
      enter, enter, // Global → Projects
      down, enter, ...type('elsewhere'), enter, // Add a project…
      enter, // elsewhere (the cursor stays on the second entry)
      down, down, down, enter, // Make default
      key(KeyCode.escape),
      end, enter, // Review and save
      char('y'),
      ctrlC,
    ]);
    final (code, err) = await run(['config', '--projects', registry], driver);
    expect(code, 0, reason: err);
    expect(driver.showed('Added elsewhere (not saved yet).'), isTrue);
    expect(driver.showed('Folder ${p.join(workspace.path, 'elsewhere')} does not exist.'), isTrue);
    expect(driver.showed('Moved elsewhere to position 1 (not saved yet).'), isTrue);
    expect(driver.showed('Saved $registry.'), isTrue, reason: driver.last);
    final saved = File(registry).readAsStringSync();
    expect(saved, startsWith('# mine\n'));
    expect(parseProjectRegistryYaml(saved, baseDir: workspace.path).entries.map((e) => e.id), ['elsewhere', 'hb']);
  });

  test('the doctor shows its findings and checks again with r', () async {
    final registry = p.join(workspace.path, 'projects.yaml');
    File(registry).writeAsStringSync('projects:\n  - id: hb\n    path: backlog\n');
    final driver = Driver([
      enter, down, down, enter, // Global → Doctor
      char('r'),
      ctrlC,
    ]);
    final (code, err) = await run(
      ['config', '--projects', registry],
      driver,
      env: {'PATH': '', 'BACKLOG_SERVER_CONFIG': p.join(workspace.path, 'server.yaml'), 'BACKLOG_PORT': '1'},
    );
    expect(code, 0, reason: err);
    expect(driver.showed('backlog config › Global › Doctor'), isTrue);
    expect(driver.showed('! backlog  not on the PATH (mise run install)'), isTrue);
    expect(driver.showed('! port 1  no server answers at http://127.0.0.1:1/api/health'), isTrue);
    expect(driver.showed('✓ hb  $backlogDir opens'), isTrue);
    expect(driver.showed('· dispatcher  no project has one'), isTrue);
    expect(driver.showed('Checked again.'), isTrue);
  });

  test('the project picker lists the registry; a missing backlog cannot be opened', () async {
    final registry = p.join(workspace.path, 'projects.yaml');
    File(registry).writeAsStringSync('projects:\n  - id: gone\n    path: nowhere\n');
    final driver = Driver([down, enter, down, enter, ctrlC]);
    final (code, _) = await run(['config', '--projects', registry], driver);
    expect(code, 0);
    expect(driver.showed('This folder'), isTrue);
    expect(driver.showed('gone'), isTrue);
    expect(driver.last, contains('does not exist'));
    expect(driver.last.split('\n').first, 'backlog config › Project');
  });

  test('a file that cannot be written keeps the review screen and the draft', () async {
    File(p.join(workspace.path, 'blocker')).writeAsStringSync('a file, not a folder');
    final registry = p.join(workspace.path, 'blocker', 'projects.yaml');
    final driver = Driver([
      enter, end, up, enter, // Global → Edit a value
      ...type('projects'), enter,
      ...type('[]'), enter,
      end, enter, // Review and save
      char('y'),
      ctrlC,
    ]);
    final (code, err) = await run(['config', '--projects', registry], driver);
    expect(code, 0, reason: err);
    expect(driver.last, contains('Cannot write $registry'));
    expect(driver.last.split('\n').first, 'backlog config › Global › Review changes');
    expect(driver.last, contains('+projects: []'));
    expect(driver.quit, isTrue);
  });

  test('needs a terminal', () async {
    final (code, err) = await run(['config'], null);
    expect(code, ExitCode.usage);
    expect(err, contains('needs an interactive terminal'));
  });

  test('runs in a dart_tui Program fed raw terminal bytes', () async {
    final seen = <String>[];
    final err = StringBuffer();
    final code = await runBacklogCli(
      ['config'],
      CliContext(
        out: StringBuffer(),
        err: err,
        cwd: workspace.path,
        runTui: (app) => Program(
          options: [
            withoutRenderer(),
            withWindowSize(100, 30),
            withOutput(IOSink(_Discard())),
            withInput(
              _slowly([
                [0x1b, 0x5b, 0x42], // down: Project
                [0x0d], // This folder
                [0x0d],
                [0x71], // q leaves everything
              ]),
            ),
            withFilter((model, msg) {
              seen.add(((model as dynamic).lines() as List<String>).map(_plain).join('\n'));
              return msg;
            }),
          ],
        ).run(app),
      ),
    );
    expect(code, 0, reason: '$err');
    expect(seen.any((frame) => frame.contains('backlog config › Project › ${p.basename(workspace.path)}')), isTrue);
  }, timeout: const Timeout(Duration(seconds: 10)));
}
