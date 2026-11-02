/// The fixture the process launcher suites share: a git repository with the
/// worktrees wt-1 and wt-2, a backlog dispatching to a fake agent and a
/// launcher. One suite per file, so the state lives in top-level variables
/// that [setUpLauncher] sets for every test.
library;

import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support.dart';

/// A fake agent: prints what it got, starts a child (to check that stopping
/// kills the whole group), then waits for `<worktree>/../go-<id>` and exits
/// with the code written there.
const _agentScript = r'''
id=$1
if [ "$2" = "--resume" ]; then session=$3; else session="sess-$id"; fi
echo "{\"type\":\"system\",\"session_id\":\"$session\"}"
echo "args $*"
echo "prompt $PROMPT"
echo "agent $BACKLOG_AGENT on $id in $(pwd) branch $(git symbolic-ref --short HEAD) backlog $BACKLOG_DIR extra $EXTRA"
sleep 30 &
echo "child $!" > "../child-$id"
while [ ! -f "../go-$id" ]; do sleep 0.05; done
code=$(cat "../go-$id")
echo "done with $code"
kill %1 2>/dev/null
exit "$code"
''';

/// How long the tests wait for the fake agent (a shell script and git) to
/// get somewhere; generous, since `mise run check` runs suites in parallel.
const patience = Duration(seconds: 30);

/// Lets the fake agent waiting for [file] exit with [code]. Written aside and
/// renamed: the agent must never read a created but still empty file (an
/// empty code made it exit with 2 instead).
void signalGo(String file, int code) {
  File('$file.tmp').writeAsStringSync('$code');
  File('$file.tmp').renameSync(file);
}

Future<String> git(String dir, List<String> arguments) async {
  final result = await Process.run('git', arguments, workingDirectory: dir);
  if (result.exitCode != 0) throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
  return '${result.stdout}'.trim();
}

late Directory root;
late Backlog backlog;
late FixedClock clock;
late ProcessAgentLauncher launcher;
late List<String> logs;
late String stateDir;

String path(String name) => p.join(root.path, name);

ProcessAgentLauncher newLauncher() => ProcessAgentLauncher(
  project: 'demo',
  backlog: () async => backlog,
  stateDir: stateDir,
  clock: clock,
  log: logs.add,
  heartbeatEvery: const Duration(minutes: 5),
  environment: {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin', 'HOME': root.path},
);

/// Sets up a fresh repository, backlog and launcher for every test.
void setUpLauncher() {
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent_launcher_');
    addTearDown(() async {
      // Leave no fake agent behind, whatever the test did.
      for (final file in root.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('child-'))) {
        final pid = int.tryParse(file.readAsStringSync().split(' ').last.trim());
        if (pid != null) Process.killPid(pid, ProcessSignal.sigkill);
      }
      for (final id in ['T-0001', 'T-0002']) {
        signalGo(path('go-$id'), 1);
      }
      // An agent may still be writing its last lines; try until it is done.
      final waited = Stopwatch()..start();
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        try {
          await root.delete(recursive: true);
          break;
        } on FileSystemException {
          if (waited.elapsed > patience) rethrow;
        }
      }
    });
    final repo = path('repo');
    await Directory(repo).create();
    await git(repo, ['init', '-q', '-b', 'main']);
    await git(repo, ['config', 'user.email', 'test@example.com']);
    await git(repo, ['config', 'user.name', 'Test']);
    File(p.join(repo, 'README.md')).writeAsStringSync('# Demo\n');
    await git(repo, ['add', '.']);
    await git(repo, ['commit', '-q', '-m', 'Initial commit']);
    for (final worktree in ['wt-1', 'wt-2']) {
      await git(repo, ['worktree', 'add', '-q', '--detach', path(worktree)]);
    }
    File(path('agent.sh')).writeAsStringSync(_agentScript);

    await Backlog.init(path('backlog'));
    File(p.join(path('backlog'), 'backlog.yaml')).writeAsStringSync('''
dispatcher:
  mode: manual
  worktrees: [wt-1, wt-2]
  agent: fake
  agents:
    fake:
      command: [sh, ${path('agent.sh')}, "{id}"]
      env: {EXTRA: "{worktree}/{branch}", PROMPT: "{prompt}"}
      output: claude-stream-json
      resume: [--resume, "{session}"]
  resume_prompt: "Continue {id}: {news}"
  actions:
    - name: Fix
      statuses: [review]
      prompt: "Fix it on {branch}"
    - name: Fix code
      statuses: [review]
      prompt: "Fix the code on {branch}"
      changes_code: true
    - name: Review
      statuses: [review]
      fresh: true
      prompt: "Review {id}"
    - name: Check
      statuses: [review]
      run: [sh, -c, "echo checking {id} on \$(git symbolic-ref --short HEAD) as \$BACKLOG_AGENT; echo out-line; exit 3"]
    - name: Noop
      run: noop
    - name: AI review
      statuses: [review]
      review: true
''');
    clock = FixedClock(DateTime.utc(2026, 10, 31, 12));
    backlog = await Backlog.open(path('backlog'), clock: clock, ids: SequentialIds());
    stateDir = path('state');
    logs = [];
    launcher = newLauncher();
    addTearDown(launcher.close);
  });
}

Future<DispatchPlan> plan() async {
  final snapshot = await backlog.planning.snapshot();
  return DispatchPlan.of(
    snapshot,
    backlogRoot: backlog.root,
    conditions: await launcher.conditions(snapshot.workflow.dispatcher!, backlog.root, snapshot),
  )!;
}

Future<PlannedItem> planned(String id) async => (await backlog.planning.snapshot())[ItemId(id)]!;

/// Lets the fake agent of [id] finish with [code] and waits until the
/// launcher has dealt with its end.
Future<void> finish(String id, int code, {ProcessAgentLauncher? by}) async {
  signalGo(path('go-$id'), code);
  final agents = by ?? launcher;
  final waited = Stopwatch()..start();
  while (waited.elapsed < patience) {
    await agents.tick();
    if (!File(p.join(stateDir, 'agents', 'demo', '$id.json')).existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('the agent for $id did not end');
}

Future<String> logOf(String id) async => (await launcher.agentLog(ItemId(id)))!.lines.join('\n');

Future<void> waitForLog(String id, String text) async {
  final waited = Stopwatch()..start();
  while (waited.elapsed < patience) {
    if ((await launcher.agentLog(ItemId(id)))?.lines.any((l) => l.contains(text)) ?? false) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('"$text" never appeared in the log of $id:\n${await logOf(id)}');
}
