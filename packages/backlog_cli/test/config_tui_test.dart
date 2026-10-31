import 'dart:io';

import 'package:backlog_cli/backlog_cli.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Plays [input] as key presses and records every frame without styling.
final class FakeTerminal implements Terminal {
  FakeTerminal(this.input);

  final List<Key> input;
  final frames = <List<String>>[];
  var opened = false;
  var closed = false;

  @override
  int get width => 100;

  @override
  int get height => 30;

  @override
  Stream<Key> get keys => Stream.fromIterable(input);

  @override
  void open() => opened = true;

  @override
  void draw(List<String> lines) =>
      frames.add([for (final line in lines) line.replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '')]);

  @override
  void close() => closed = true;

  String get last => frames.last.join('\n');

  bool showed(String text) => frames.any((frame) => frame.join('\n').contains(text));
}

List<Key> type(String text) => [for (final char in text.split('')) Key.char(char)];

const enter = Key(KeyKind.enter);
const up = Key(KeyKind.up);
const down = Key(KeyKind.down);
const end = Key(KeyKind.end);
const backspace = Key(KeyKind.backspace);

void main() {
  late Directory workspace;
  late String backlogDir;

  Future<(int, String)> run(List<String> args, Terminal? terminal, {Map<String, String> env = const {}}) async {
    final err = StringBuffer();
    final code = await runBacklogCli(
      args,
      CliContext(
        out: StringBuffer(),
        err: err,
        cwd: workspace.path,
        environment: env,
        terminal: terminal == null ? null : () => terminal,
      ),
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
    final terminal = FakeTerminal([
      ...openValueEditor,
      ...type('claims.lease_minutes'),
      enter,
      backspace, backspace, backspace, ...type('60'), enter, // the value was 240
      end, enter, // Review and save
      const Key.char('y'),
      const Key.char('q'),
    ]);
    final (code, err) = await run(['config'], terminal);
    expect(code, 0, reason: err);
    expect(terminal.opened && terminal.closed, isTrue);
    expect(terminal.showed('backlog config › Project › ${p.basename(workspace.path)}'), isTrue);
    expect(terminal.showed('not yet: statuses'), isTrue);
    expect(terminal.showed('> 240'), isTrue);
    expect(terminal.showed('-  lease_minutes: 240'), isTrue);
    expect(terminal.showed('+  lease_minutes: 60'), isTrue);
    expect(terminal.showed('Valid. Save?'), isTrue);
    expect(terminal.showed('Saved ${config().path}.'), isTrue);
    expect(
      config().readAsStringSync(),
      contains('  lease_minutes: 60   # a claim without heartbeat expires after this'),
    );
    expect(config().readAsStringSync(), contains('# Backlog configuration.'));
  });

  test('an invalid draft cannot be saved and leaving asks about unsaved changes', () async {
    final before = config().readAsStringSync();
    final terminal = FakeTerminal([
      ...openValueEditor,
      ...type('claims.lease_minutes'),
      enter,
      backspace, backspace, backspace, ...type('soon'), enter,
      end, enter,
      const Key.char('y'), // refused
      const Key.char('n'),
      const Key.char('q'),
      const Key.char('y'), // discard and leave the project
      const Key.char('q'),
    ]);
    final (code, err) = await run(['config'], terminal);
    expect(code, 0, reason: err);
    expect(terminal.showed('Cannot save: '), isTrue);
    expect(terminal.showed('claims.lease_minutes must be an integer'), isTrue);
    expect(terminal.showed('Unsaved changes (2 changed lines).'), isTrue);
    expect(terminal.showed('without saving 2 changed lines?'), isTrue);
    expect(terminal.frames.last.first, 'backlog config › Project');
    expect(config().readAsStringSync(), before);
  });

  test('the global part shows the project registry', () async {
    final registry = p.join(workspace.path, 'projects.yaml');
    File(registry).writeAsStringSync('projects:\n  - id: hb\n    name: Hobby\n    path: backlog\n    pinned: true\n');
    final terminal = FakeTerminal([enter, enter, const Key(KeyKind.interrupt)]);
    final (code, err) = await run(['config', '--projects', registry], terminal);
    expect(code, 0, reason: err);
    expect(terminal.last, contains('backlog config › Global › Projects'));
    expect(terminal.last, contains('hb  Hobby  $backlogDir  (default)  (pinned)'));
    expect(terminal.closed, isTrue);
  });

  test('the project picker lists the registry; a missing backlog cannot be opened', () async {
    final registry = p.join(workspace.path, 'projects.yaml');
    File(registry).writeAsStringSync('projects:\n  - id: gone\n    path: nowhere\n');
    final terminal = FakeTerminal([down, enter, down, enter, const Key(KeyKind.interrupt)]);
    final (code, _) = await run(['config', '--projects', registry], terminal);
    expect(code, 0);
    expect(terminal.showed('This folder'), isTrue);
    expect(terminal.showed('gone'), isTrue);
    expect(terminal.last, contains('does not exist'));
    expect(terminal.last.split('\n').first, 'backlog config › Project');
  });

  test('a file that cannot be written keeps the review screen and the draft', () async {
    File(p.join(workspace.path, 'blocker')).writeAsStringSync('a file, not a folder');
    final registry = p.join(workspace.path, 'blocker', 'projects.yaml');
    final terminal = FakeTerminal([
      enter, end, up, enter, // Global → Edit a value
      ...type('projects'), enter,
      ...type('[]'), enter,
      end, enter, // Review and save
      const Key.char('y'),
      const Key(KeyKind.interrupt),
    ]);
    final (code, err) = await run(['config', '--projects', registry], terminal);
    expect(code, 0, reason: err);
    expect(terminal.last, contains('Cannot write $registry'));
    expect(terminal.last.split('\n').first, 'backlog config › Global › Review changes');
    expect(terminal.last, contains('+projects: []'));
    expect(terminal.closed, isTrue);
  });

  test('needs a terminal', () async {
    final (code, err) = await run(['config'], null);
    expect(code, ExitCode.usage);
    expect(err, contains('needs an interactive terminal'));
  });

  test('decodes keys from raw terminal input', () {
    expect(decodeKeys('a\x1b[A\x1b[B\x1b[1;5C\x1bOD\r\x7f\x1b[3~\x1b[5~\x1b'.codeUnits), [
      const Key.char('a'),
      up,
      down,
      const Key(KeyKind.right),
      const Key(KeyKind.left),
      enter,
      backspace,
      const Key(KeyKind.delete),
      const Key(KeyKind.pageUp),
      const Key(KeyKind.escape),
    ]);
    expect(decodeKeys([0xc5, 0xbe, 0xf0, 0x9f, 0x98, 0x80]), [const Key.char('ž'), const Key.char('😀')]);
  });
}
