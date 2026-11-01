import 'package:backlog_core/backlog_core.dart';
import 'package:test/test.dart';

const _config = '''
id: {prefix: HB, length: 4}
# Agents.
dispatcher:
  mode: manual   # start by hand
  worktrees:
    - hb-2
    - {name: hb-3, path: /work/hb-3}
  agents:
    mine:
      command: my-agent --task {prompt}
''';

void main() {
  test('reads and edits mode, limits, worktrees and the agent', () {
    final settings = DispatcherSettings(ConfigDraft(_config));
    expect(settings.enabled, isTrue);
    expect(settings.mode, 'manual');
    expect(settings.worktrees.map((w) => (w.name, w.path)), [('hb-2', '../hb-2'), ('hb-3', '/work/hb-3')]);
    expect(settings.profiles, containsAll(['claude', 'codex', 'mine']));
    expect(settings.agent, 'claude');

    settings
      ..setMode('auto')
      ..setNumber('max_agents', '2')
      ..addWorktree('hb-4')
      ..addWorktree('hb-5', path: '/elsewhere/hb-5')
      ..setWorktreePath(1, '')
      ..removeWorktree(0)
      ..setText('base', 'develop')
      ..setAgent('mine');
    expect(settings.draft.text, contains('mode: auto   # start by hand'));
    final config = parseWorkflowYaml(settings.draft.text).dispatcher!;
    expect(config.mode, DispatchMode.auto);
    expect(config.maxAgents, 2);
    expect(config.worktrees.map((w) => (w.name, w.path)), [
      ('hb-3', '../hb-3'),
      ('hb-4', '../hb-4'),
      ('hb-5', '/elsewhere/hb-5'),
    ]);
    expect(config.base, 'develop');
    expect(config.agent.name, 'mine');

    settings.setNumber('max_agents', '');
    expect(settings.text('max_agents'), isNull);
    expect(() => settings.setMode('fast'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setNumber('max_agents', '0'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.addWorktree('hb-4'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.addWorktree('a b'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setText('worktree_name', 'agent'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setText('base', '-x'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setAgent('nobody'), throwsA(isA<InvalidInputException>()));
  });

  test('a file without a dispatcher gets one with its first worktree', () {
    final settings = DispatcherSettings(ConfigDraft(''))..addWorktree('w1');
    expect(parseWorkflowYaml(settings.draft.text).dispatcher!.worktrees.single.name, 'w1');
  });

  test('previews the command with the placeholders filled in', () {
    final settings = DispatcherSettings(ConfigDraft(_config))..setAgent('mine');
    final preview = previewDispatcher(settings.draft.text, backlogRoot: '/p/hobby/backlog')!;
    expect(preview.profile, 'mine');
    expect(preview.values['id'], 'HB-7f3a');
    expect(preview.values['path'], '/p/hobby/hb-2');
    expect(preview.prompt, contains('HB-7f3a'));
    expect(preview.command, startsWith("my-agent --task '"));
    expect(preview.command, contains('agent/HB-7f3a'));
    expect(previewDispatcher('', backlogRoot: '/p'), isNull);
    expect(() => previewDispatcher('dispatcher: {}', backlogRoot: '/p'), throwsA(isA<ConfigurationException>()));
  });
}
