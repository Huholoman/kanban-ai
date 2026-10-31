import 'dart:math';

import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_core/src/workflow/infrastructure/yaml_workflow.dart' show workflowTemplate;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('Workflow', () {
    test('standard workflow derives statuses by category', () {
      final workflow = Workflow.standard();
      expect(workflow.activeStatus, 'in-progress');
      expect(workflow.doneStatus, 'done');
      expect(workflow.pickableStatus, 'todo');
      expect(workflow.priorityRank('p0'), lessThan(workflow.priorityRank('p3')));
      expect(workflow.priorityRank('nonsense'), workflow.priorities.length);
    });

    test('rejects a workflow without a done status', () {
      expect(
        () => Workflow(
          statuses: const [
            StatusDefinition('todo', StatusCategory.open, pickable: true),
            StatusDefinition('doing', StatusCategory.active),
          ],
          priorities: const ['p1'],
          types: const ['task'],
        ),
        throwsA(isA<ConfigurationException>()),
      );
    });

    test('parses backlog.yaml and keeps standard values for missing sections', () {
      final workflow = parseWorkflowYaml('''
id: {prefix: HB, length: 5}
priorities: [urgent, normal, low]
milestones:
  - id: launch
    title: Launch
claims: {lease_minutes: 30}
''');
      expect(workflow.idPrefix, 'HB');
      expect(workflow.idLength, 5);
      expect(workflow.priorities, ['urgent', 'normal', 'low']);
      expect(workflow.defaultPriority, 'normal');
      expect(workflow.statuses.map((s) => s.id), contains('in-progress'));
      expect(workflow.acceptsMilestone('launch'), isTrue);
      expect(workflow.acceptsMilestone('other'), isFalse);
      expect(workflow.claimLease, const Duration(minutes: 30));
    });

    test('reads appearance colours in any accepted spelling', () {
      final appearance = parseWorkflowYaml('''
appearance:
  mode: dark
  light: {seed: "#3F51B5", background: fafafa}
  dark: {seed: "#abc"}
  statuses: {todo: "#1e88e5"}
  priorities: {p0: "e53935"}
  labels: {infra: "#00897b"}
''').appearance;
      expect(appearance.mode, 'dark');
      expect(appearance.light.seed, '#3f51b5');
      expect(appearance.light.background, '#fafafa');
      expect(appearance.dark.seed, '#aabbcc');
      expect(appearance.dark.primary, isNull);
      expect(appearance.statuses, {'todo': '#1e88e5'});
      expect(appearance.priorities, {'p0': '#e53935'});
      expect(appearance.labels, {'infra': '#00897b'});
      expect(Workflow.standard().appearance.mode, 'system');
    });

    test('rejects bad colours and modes', () {
      expect(
        () => parseWorkflowYaml('appearance: {statuses: {todo: "blue"}}'),
        throwsA(
          isA<ConfigurationException>().having((e) => e.message, 'message', contains('appearance.statuses.todo')),
        ),
      );
      expect(() => parseWorkflowYaml('appearance: {mode: dim}'), throwsA(isA<ConfigurationException>()));
    });

    test('the init template parses, including its commented appearance and dispatcher', () {
      final template = workflowTemplate(idPrefix: 'X');
      expect(parseWorkflowYaml(template).appearance.mode, 'system');
      final start = template.indexOf('# appearance:');
      final uncommented =
          template.substring(0, start) +
          template.substring(start).replaceAll(RegExp(r'^# (?=\s*(- |[a-z_-]+:))', multiLine: true), '');
      expect(parseWorkflowYaml(uncommented).appearance.priorities['p0'], '#e53935');
      expect(parseWorkflowYaml(uncommented).dispatcher!.worktrees.map((w) => w.name), ['monorepo-2', 'monorepo-3']);
      expect(parseWorkflowYaml(uncommented).dispatcher!.actions.map((a) => a.name), [
        'Address PR comments',
        'AI review',
        'Tests',
      ]);
    });

    test('the dispatcher is off without its section', () {
      expect(Workflow.standard().dispatcher, isNull);
      expect(parseWorkflowYaml('claims: {lease_minutes: 30}').dispatcher, isNull);
    });

    test('parses the dispatcher section', () {
      final dispatcher = parseWorkflowYaml('''
dispatcher:
  mode: auto
  max_agents: 1
  worktrees:
    - name: repo-2
      path: /work/repo-2
    - repo-3
  command: claude -p "Work on {id} ({title})" --cwd {path}
''').dispatcher!;
      expect(dispatcher.mode, DispatchMode.auto);
      expect(dispatcher.maxAgents, 1);
      expect(dispatcher.worktrees.map((w) => w.name), ['repo-2', 'repo-3']);
      expect(dispatcher.worktree('repo-2')!.resolvePath('/work/backlog'), '/work/repo-2');
      expect(dispatcher.worktree('repo-3')!.resolvePath('/work/backlog'), '/work/repo-3');
      expect(dispatcher.command.arguments, ['claude', '-p', 'Work on {id} ({title})', '--cwd', '{path}']);
      expect(dispatcher.command.render({'id': 'X-1', 'title': "It's \$HOME", 'path': '/w'}), [
        'claude',
        '-p',
        "Work on X-1 (It's \$HOME)",
        '--cwd',
        '/w',
      ]);
    });

    test('dispatcher defaults: manual, one agent per worktree, command as a list', () {
      final dispatcher = parseWorkflowYaml('''
dispatcher:
  worktrees: [a, b]
  command: [sh, -c, "echo {{literal}} {id}"]
''').dispatcher!;
      expect(dispatcher.mode, DispatchMode.manual);
      expect(dispatcher.maxAgents, 2);
      expect(dispatcher.command.render({'id': 'X-1'}), ['sh', '-c', 'echo {literal} X-1']);
    });

    test('dispatcher.pr: create, find, remote and url_pattern; the default prompts follow it', () {
      final plain = parseWorkflowYaml('dispatcher: {worktrees: [a]}').dispatcher!;
      expect(plain.pr, isNull);
      expect(plain.prompt.text, contains('Never push'));
      expect(plain.prompt.text, isNot(contains('backlog pr')));

      final tea = parseWorkflowYaml('''
dispatcher:
  worktrees: [a]
  pr:
    create: 'tea pulls create --head {branch} --base {base} --title "{id}: {title}" --description-file -'
''').dispatcher!;
      final pr = tea.pr!;
      expect(pr.remote, 'origin');
      expect(pr.find, isNull);
      expect(pr.create.render({'id': 'X-1', 'title': 'Do it', 'branch': 'agent/X-1', 'base': 'main'}), [
        'tea', 'pulls', 'create', '--head', 'agent/X-1', '--base', 'main', '--title', 'X-1: Do it', //
        '--description-file', '-',
      ]);
      expect(tea.prompt.text, DispatcherConfig.defaultPullRequestPrompt);
      expect(tea.prompt.text, allOf(contains('backlog pr {id} --description'), contains('Never run `git push`')));
      expect(tea.resumePrompt.text, contains('backlog pr {id}'));
      expect(
        pr.urlIn('\x1B[1m#12\x1B[0m Do it\nhttps://git.example/o/r/pulls/12\n'),
        'https://git.example/o/r/pulls/12',
      );
      expect(pr.urlIn('no link'), isNull);

      final custom = parseWorkflowYaml('''
dispatcher:
  worktrees: [a]
  prompt: Mine {id}
  pr:
    remote: upstream
    create: [gh, pr, create, --body-file, "-"]
    find: [gh, pr, list, --head, "{branch}", --json, url, --jq, ".[0].url"]
    url_pattern: 'see (\\S+) for'
''').dispatcher!;
      expect(custom.prompt.text, 'Mine {id}', reason: 'an own prompt wins');
      expect(custom.pr!.remote, 'upstream');
      expect(custom.pr!.find!.arguments, contains('{branch}'));
      expect(
        custom.pr!.urlIn('https://x.example/a see https://x.example/pull/1 for details'),
        'https://x.example/pull/1',
      );

      void rejects(String pr, String message) => expect(
        () => parseWorkflowYaml('dispatcher:\n  worktrees: [a]\n  pr: $pr\n'),
        throwsA(isA<ConfigurationException>().having((e) => e.message, 'message', contains(message))),
      );
      rejects('{remote: origin}', 'dispatcher.pr.create is required');
      rejects('{create: x, merge: y}', 'unknown key "dispatcher.pr.merge"');
      rejects('{create: "tea {worktree}"}', 'unknown placeholder "{worktree}"');
      rejects('{create: "tea {pr_number}"}', 'unknown placeholder "{pr_number}"');
      rejects('{create: x, review: "tea comment {description}"}', 'unknown placeholder "{description}"');
      expect(
        parseWorkflowYaml(
          'dispatcher:\n  worktrees: [a]\n  pr: {create: x, review: "tea comment {pr_number} {body} {verdict} {pr}"}\n',
        ).dispatcher!.pr!.review!.executable,
        'tea',
      );
      rejects('{create: x, remote: --force}', 'not a remote name');
      rejects('{create: x, url_pattern: "("}', 'url_pattern is not a regular expression');
      rejects('{create: ""}', 'must not be empty');
    });

    test('agent profiles: claude by default, built-in by name, own ones in agents', () {
      final byDefault = parseWorkflowYaml('dispatcher: {worktrees: [a]}').dispatcher!;
      expect(byDefault.agent.name, 'claude');
      expect(byDefault.agent.output, AgentOutput.claudeStreamJson);
      expect(byDefault.prompt.text, DispatcherConfig.defaultPrompt);
      final claude = byDefault.command.arguments;
      expect(claude.take(3), ['claude', '-p', '{prompt}']);
      expect(claude, containsAllInOrder(['--permission-mode', 'acceptEdits', '--allowedTools']));
      final allowed = claude[claude.indexOf('--allowedTools') + 1];
      for (final tool in ['Bash(backlog *)', 'Bash(git *)', 'Bash(mise run *)', 'Bash(./*)', 'Edit']) {
        expect(allowed, contains(tool), reason: 'the project\'s scripts (./greet.sh) run too');
      }
      expect(claude, isNot(contains('--bare')));
      expect(claude, isNot(contains('--dangerously-skip-permissions')));
      final denied = claude[claude.indexOf('--disallowedTools') + 1];
      for (final rule in ['Bash(git push *)', 'Bash(git -*)', 'Bash(git send-pack *)', 'Bash(git config *alias*)']) {
        expect(denied, contains(rule), reason: '`git -C . push` slips past Bash(git push *) alone');
      }

      expect(parseWorkflowYaml('dispatcher: {agent: codex, worktrees: [a]}').dispatcher!.agent.verified, isFalse);

      final own = parseWorkflowYaml('''
dispatcher:
  worktrees: [a]
  agent: mine
  agents:
    mine:
      command: [my-agent, --task, "{prompt}"]
      env: {MY_NAME: "{worktree}-{id}"}
      output: json-lines
    claude: {command: 'claude -p {prompt}'}
  prompt: Do {id} ({title}) as {worktree}.
''').dispatcher!;
      expect(own.agent.name, 'mine');
      expect(own.agent.output, AgentOutput.jsonLines);
      expect(own.agent.builtIn, isFalse);
      final plan = DispatchPlan.of(
        BacklogSnapshot.build(
          items: [item('X-1')],
          workflow: parseWorkflowYaml(
            'dispatcher: {worktrees: [a], agent: mine, agents: {mine: {command: [my-agent, "{prompt}"], '
            'env: {MY_NAME: "{worktree}-{id}"}}}, prompt: "Do {id} ({title}) as {worktree}."}',
          ),
          claims: const [],
          now: DateTime.utc(2026, 10, 29),
        ),
        backlogRoot: '/w/backlog',
      )!;
      final assignment = plan.assignments.single;
      expect(assignment.prompt, 'Do X-1 (Item X-1) as a.');
      expect(assignment.command, ['my-agent', 'Do X-1 (Item X-1) as a.']);
      expect(assignment.environment, {'BACKLOG_AGENT': 'a', 'BACKLOG_DIR': '/w/backlog', 'MY_NAME': 'a-X-1'});
    });

    test('the legacy command is a plain profile without a prompt of its own', () {
      final dispatcher = parseWorkflowYaml('dispatcher: {worktrees: [a], command: "run {id} {prompt}"}').dispatcher!;
      expect(dispatcher.agent.name, 'command');
      expect(dispatcher.agent.output, AgentOutput.text);
      expect(dispatcher.command.arguments, ['run', '{id}', '{prompt}']);
    });

    test('parses worktrees on demand: repo, name pattern, limit, cleanup', () {
      final dispatcher = parseWorkflowYaml('''
dispatcher:
  worktrees: [app-9]
  repo: ../src/app
  max_worktrees: 3
  cleanup_after_days: 7
''').dispatcher!;
      final added = dispatcher.newWorktrees!;
      expect(dispatcher.maxAgents, 3, reason: 'max_agents defaults to max_worktrees');
      expect(added.maxWorktrees, 3);
      expect(added.cleanupAfter, const Duration(days: 7));
      expect(added.resolveRepo('/work/backlog'), '/work/src/app');
      expect(added.nameFor(2), 'app-2');
      expect(added.worktree('app-2', '/work/backlog').path, '/work/src/app-2');

      final own = parseWorkflowYaml('''
dispatcher:
  repo: /x/mono
  worktree_name: "agent{n}"
  max_agents: 2
''').dispatcher!;
      expect(own.worktrees, isEmpty);
      expect(own.newWorktrees!.maxWorktrees, 2);
      expect(own.newWorktrees!.cleanupAfter, isNull);
      expect(own.newWorktrees!.nameFor(4), 'agent4');
    });

    test('splits a command string like a shell, without running one', () {
      expect(CommandTemplate.splitWords(r"""a  'b c' "d \"e\" \$f" g\ h ''"""), ['a', 'b c', r'd "e" $f', 'g h', '']);
      expect(() => CommandTemplate.splitWords('a "b'), throwsA(isA<ConfigurationException>()));
    });

    test('parses actions: buttons per status, on_enter hooks, prompt, command or built-in', () {
      final dispatcher = parseWorkflowYaml('''
dispatcher:
  worktrees: [a]
  agents:
    reviewer: {command: "rev {prompt}"}
  actions:
    - name: Fix PR comments
      statuses: [review]
      prompt: "Fix the comments of {pr} on {branch}"
    - name: AI review
      on_enter: review
      fresh: true
      agent: reviewer
      prompt: "Review {id}: {news}"
    - name: Merge
      on_enter: done
      statuses: []
      run: noop
    - name: Tests
      run: [sh, -c, "cd {path} && mise run check # {id} {pr} {base}"]
''').dispatcher!;
      final [fix, review, merge, tests] = dispatcher.actions;
      expect(fix.kind, ActionKind.prompt);
      expect([fix.offeredIn('review'), fix.offeredIn('todo')], [true, false]);
      expect(fix.fresh, isFalse);
      expect(dispatcher.profileFor(fix).name, 'claude');
      expect(review.onEnter, 'review');
      expect([review.offeredIn('review'), review.offeredIn('todo')], [true, false]);
      expect(dispatcher.profileFor(review).name, 'reviewer');
      expect(review.fresh, isTrue);
      expect(merge.kind, ActionKind.builtIn);
      expect(merge.builtIn, 'noop');
      expect(merge.offeredIn('done'), isFalse);
      expect(tests.kind, ActionKind.command);
      expect([tests.offeredIn('todo'), tests.offeredIn('done')], [true, true]);
      expect(tests.command!.render({'path': '/w', 'id': 'X-1', 'pr': '7', 'base': 'main'}), [
        'sh',
        '-c',
        'cd /w && mise run check # X-1 7 main',
      ]);
      expect(dispatcher.action('Merge'), same(merge));
      expect([fix.review, review.review], [false, false]);

      final [builtIn, extra] = parseWorkflowYaml('''
dispatcher:
  worktrees: [a]
  actions:
    - {name: AI review, review: true, on_enter: review}
    - {name: Security review, review: true, statuses: [review], agent: claude, prompt: "Focus on {branch}."}
''').dispatcher!.actions;
      expect((builtIn.kind, builtIn.review, builtIn.fresh, builtIn.prompt), (ActionKind.prompt, true, true, null));
      expect(builtIn.summary, 'AI review, agent, new session');
      expect((extra.review, extra.prompt!.render({'branch': 'b'})), (true, 'Focus on b.'));
      expect(dispatcher.action('merge'), isNull);
    });

    test('rejects broken actions', () {
      void rejects(String actions, String message) => expect(
        () => parseWorkflowYaml('dispatcher: {worktrees: [a], actions: [$actions]}'),
        throwsA(isA<ConfigurationException>().having((e) => e.message, 'message', contains(message))),
      );
      rejects('{name: A}', 'give exactly one of prompt, run and review');
      rejects('{name: A, prompt: x, run: noop}', 'give exactly one of prompt, run and review');
      rejects('{name: A, review: true, run: noop}', 'a review runs an agent; it takes no run');
      rejects('{name: A, review: true, fresh: false}', 'a review always runs in a new session');
      rejects('{name: A, review: yes please}', 'review must be true or false');
      rejects('{name: A, run: "mise run check"}', 'unknown built-in action "mise run check" (known: noop)');
      rejects('{name: A, prompt: x}, {name: A, run: noop}', 'Duplicate dispatcher action "A"');
      rejects('{name: A, prompt: x, on_enter: reviewed}', 'unknown status "reviewed"');
      rejects('{name: A, prompt: x, statuses: [todo, nope]}', 'unknown status "nope"');
      rejects('{name: A, prompt: x, agent: robot}', 'unknown agent "robot"');
      rejects('{name: A, run: noop, fresh: true}', 'only apply to prompt actions');
      rejects('{name: A, prompt: x, fresh: yes please}', 'fresh must be true or false');
      rejects('{name: A, prompt: "{prompt}"}', 'unknown placeholder "{prompt}"');
      rejects('{name: A, run: [x, "{news}"]}', 'unknown placeholder "{news}"');
      rejects('{name: A/B, run: noop}', 'must not contain "/"');
      rejects('{name: A, run: noop, when: now}', 'unknown key "dispatcher.actions[].when"');
    });

    test('rejects a broken dispatcher section', () {
      void rejects(String yaml, String message) => expect(
        () => parseWorkflowYaml(yaml),
        throwsA(isA<ConfigurationException>().having((e) => e.message, 'message', contains(message))),
      );
      rejects('dispatcher: {agent: claude, command: x, worktrees: [a]}', 'not both');
      rejects(
        'dispatcher: {agent: robot, worktrees: [a]}',
        'unknown agent "robot" (known: claude, codex, gemini, aider)',
      );
      rejects('dispatcher: {agents: {x: {env: {}}}, worktrees: [a]}', 'dispatcher.agents.x.command is required');
      rejects(
        'dispatcher: {agents: {x: {command: y, mode: z}}, worktrees: [a]}',
        'unknown key "dispatcher.agents.x.mode"',
      );
      rejects(
        'dispatcher: {agents: {x: {command: y, output: xml}}, worktrees: [a]}',
        'dispatcher.agents.x.output must be one of',
      );
      rejects(
        'dispatcher: {agents: {x: {command: "y {item}"}}, worktrees: [a]}',
        'dispatcher.agents.x.command: unknown placeholder',
      );
      rejects(
        'dispatcher: {agents: {x: {command: y, env: {"A-B": c}}}, worktrees: [a]}',
        'not a valid environment variable',
      );
      rejects(
        'dispatcher: {prompt: "do {prompt}", worktrees: [a]}',
        'dispatcher.prompt: unknown placeholder "{prompt}"',
      );
      rejects('dispatcher: {command: x}', 'dispatcher.worktrees (or dispatcher.repo) is required');
      rejects('dispatcher: {repo: ../r}', 'needs dispatcher.max_worktrees');
      rejects('dispatcher: {repo: ../r, max_worktrees: 2, worktree_name: "{repo}"}', 'must contain {n}');
      rejects('dispatcher: {repo: ../r, max_worktrees: 2, worktree_name: "a/{n}"}', 'not a worktree name');
      rejects('dispatcher: {repo: ../r, max_worktrees: 2, worktree_name: "{x}-{n}"}', 'unknown placeholder "{x}"');
      rejects('dispatcher: {repo: ../r, max_worktrees: 1, worktrees: [a, b]}', 'less than the 2 listed');
      rejects('dispatcher: {repo: ../r, max_worktrees: 2, cleanup_after_days: 0}', 'at least 1');
      rejects('dispatcher: {worktrees: [a], max_worktrees: 2}', 'dispatcher.max_worktrees needs dispatcher.repo');
      rejects('dispatcher: {command: x, worktrees: []}', 'at least one worktree');
      rejects('dispatcher: {command: x, worktrees: [a, a]}', 'Duplicate dispatcher worktree "a"');
      rejects('dispatcher: {command: x, worktrees: ["a b"]}', 'Worktree name "a b"');
      rejects('dispatcher: {command: x, worktrees: [a], mode: sometimes}', 'auto or manual');
      rejects('dispatcher: {command: x, worktrees: [a], max_agents: 0}', 'at least 1');
      rejects('dispatcher: {command: x, worktrees: [a], max_agents: two}', 'must be an integer');
      rejects('dispatcher: {command: "run {item}", worktrees: [a]}', 'unknown placeholder "{item}"');
      rejects('dispatcher: {command: x, worktrees: [a], max_agent: 1}', 'unknown key "dispatcher.max_agent"');
      rejects('dispatcher: {command: "", worktrees: [a]}', 'must not be empty');
    });

    test('free-form milestones when none are listed', () {
      expect(Workflow.standard().acceptsMilestone('anything'), isTrue);
    });
  });

  group('ItemReference', () {
    final known = ['T-7f3a', 'T-7f9b', 'T-a2c4'].map(ItemId.new).toList();

    test('resolves exact, case-insensitive, suffix and prefix references', () {
      expect(ItemReference.resolve('T-7f3a', known), ItemId('T-7f3a'));
      expect(ItemReference.resolve('t-7F3A', known), ItemId('T-7f3a'));
      expect(ItemReference.resolve('a2c4', known), ItemId('T-a2c4'));
      expect(ItemReference.resolve('a2', known), ItemId('T-a2c4'));
      expect(ItemReference.resolve('T-7f3', known), ItemId('T-7f3a'));
    });

    test('reports ambiguity and absence', () {
      expect(
        () => ItemReference.resolve('7f', known),
        throwsA(isA<AmbiguousReferenceException>().having((e) => e.candidates, 'candidates', hasLength(2))),
      );
      expect(() => ItemReference.resolve('zzz', known), throwsA(isA<NotFoundException>()));
    });
  });

  test('RandomIdGenerator uses the prefix and the readable alphabet', () {
    final ids = RandomIdGenerator(prefix: 'HB', length: 6, random: Random(1));
    for (var i = 0; i < 100; i++) {
      expect(ids.next().value, matches(RegExp(r'^HB-[23456789abcdefghjkmnpqrstuvwxyz]{6}$')));
    }
  });

  test('Checklist counts task-list lines outside code fences', () {
    final checklist = Checklist.parse('''
## Done
- [x] first
* [X] second
1. [ ] third
- [ ] fourth
```
- [ ] not a task
```
- plain item
''');
    expect(checklist.done, 2);
    expect(checklist.total, 4);
  });

  test('FieldChange parses set, add, remove and clear', () {
    expect(FieldChange.parse('status=done').op, ChangeOp.set);
    expect(FieldChange.parse('labels+=a, b').values, ['a', 'b']);
    expect(FieldChange.parse('depends_on-=T-1').op, ChangeOp.remove);
    expect(FieldChange.parse('milestone=').clears, isTrue);
    expect(FieldChange.parse('title=Fix: a = b').value, 'Fix: a = b');
    expect(() => FieldChange.parse('nonsense'), throwsA(isA<InvalidInputException>()));
    expect(FieldChange.parse('touches+=lib/*.{dart,yaml}, docs/').values, ['lib/*.{dart,yaml}', 'docs/']);
  });

  group('BacklogSnapshot', () {
    test('an item is blocked until its dependencies are done', () {
      final snapshot = snapshotOf([
        item('T-1', status: 'in-progress'),
        item('T-2', dependsOn: ['T-1']),
        item('T-3', dependsOn: ['T-4']),
        item('T-4', status: 'done'),
      ]);
      expect(snapshot[ItemId('T-2')]!.isBlocked, isTrue);
      expect(snapshot[ItemId('T-2')]!.openDependencies, [ItemId('T-1')]);
      expect(snapshot[ItemId('T-3')]!.isBlocked, isFalse);
      expect(snapshot.ready.map((i) => i.id.value), ['T-3']);
      expect(snapshot.dependentsOf(ItemId('T-1')).map((i) => i.id.value), ['T-2']);
    });

    test('a missing dependency blocks too', () {
      final planned = snapshotOf([
        item('T-1', dependsOn: ['T-404']),
      ])[ItemId('T-1')]!;
      expect(planned.isBlocked, isTrue);
      expect(planned.missingDependencies, [ItemId('T-404')]);
    });

    test('only pickable statuses are ready, and parents wait for children', () {
      final snapshot = snapshotOf([
        item('T-1', status: 'backlog'),
        item('E-1', type: 'epic'),
        item('T-2', parent: 'E-1'),
        item('T-3', parent: 'E-1', status: 'done'),
      ]);
      expect(snapshot.ready.map((i) => i.id.value), ['T-2']);
      expect(snapshot[ItemId('E-1')]!.childCount, 2);
      expect(snapshot[ItemId('E-1')]!.openChildCount, 1);
    });

    test('a live claim hides an item from ready, an expired one does not', () {
      final now = DateTime.utc(2026, 10, 29, 12);
      Claim claimAt(String id, DateTime at) =>
          Claim(itemId: ItemId(id), agent: 'a', claimedAt: at, heartbeatAt: at, lease: const Duration(hours: 1));
      final snapshot = snapshotOf(
        [item('T-1'), item('T-2')],
        claims: [claimAt('T-1', now), claimAt('T-2', now.subtract(const Duration(hours: 2)))],
        now: now,
      );
      expect(snapshot[ItemId('T-1')]!.isClaimed, isTrue);
      expect(snapshot[ItemId('T-2')]!.isClaimExpired, isTrue);
      expect(snapshot.ready.map((i) => i.id.value), ['T-2']);
    });

    test('an open item whose touches overlap active work waits for it', () {
      final snapshot = snapshotOf([
        item('T-1', status: 'in-progress', touches: ['lib/payments/']),
        item('T-2', status: 'review', touches: ['docs/*.md']),
        item('T-3', touches: ['lib/payments/stripe.dart']),
        item('T-4', touches: ['lib/orders/', 'docs/payments.md']),
        item('T-5', touches: ['lib/orders/']),
        item('T-6'), // no touches: never conflicts
        item('T-7', status: 'backlog', touches: ['lib/**']),
        item('T-8', status: 'done', touches: ['lib/payments/']),
        item('T-9', status: 'in-progress', touches: ['lib/payments/']), // active ones do not wait
      ]);
      List<String> conflicts(String id) => [for (final c in snapshot[ItemId(id)]!.conflictsWith) c.value];
      expect(conflicts('T-3'), ['T-1', 'T-9']);
      expect(conflicts('T-4'), ['T-2']);
      expect(conflicts('T-5'), isEmpty);
      expect(conflicts('T-6'), isEmpty);
      expect(conflicts('T-7'), ['T-1', 'T-9']); // open but not pickable: waits, still not ready
      expect(conflicts('T-8'), isEmpty);
      expect(conflicts('T-9'), isEmpty);
      expect(snapshot[ItemId('T-3')]!.isConflicting, isTrue);
      expect(snapshot[ItemId('T-3')]!.isBlocked, isFalse);
      expect(snapshot.ready.map((i) => i.id.value), unorderedEquals(['T-5', 'T-6']));
      expect(snapshot.conflicting.map((i) => i.id.value), unorderedEquals(['T-3', 'T-4', 'T-7']));
      expect(snapshot.waitingOn(ItemId('T-1')).map((i) => i.id.value), unorderedEquals(['T-3', 'T-7']));
      final view = parseFilter({'conflicting': true, 'conflicts_with': 'T-2'});
      expect(snapshot.items.where(view.matches).map((i) => i.id.value), ['T-4']);
    });

    test('orders by priority, then creation date', () {
      final snapshot = snapshotOf([
        item('T-1', priority: 'p2', created: '2026-01-01'),
        item('T-2', priority: 'p0', created: '2026-05-01'),
        item('T-3', priority: 'p2', created: '2025-12-01'),
      ]);
      expect(snapshot.items.map((i) => i.id.value), ['T-2', 'T-3', 'T-1']);
    });

    test('finds dependency and parent cycles', () {
      final snapshot = snapshotOf([
        item('T-1', dependsOn: ['T-2']),
        item('T-2', dependsOn: ['T-3']),
        item('T-3', dependsOn: ['T-1']),
        item('T-4', dependsOn: ['T-1']),
        item('T-5', parent: 'T-6'),
        item('T-6', parent: 'T-5'),
      ]);
      expect(snapshot.dependencyCycles(), hasLength(1));
      expect(snapshot.dependencyCycles().single.toSet(), {ItemId('T-1'), ItemId('T-2'), ItemId('T-3')});
      expect(snapshot.parentCycles(), hasLength(1));
    });
  });

  group('views', () {
    final snapshot = snapshotOf([
      item('T-1', status: 'todo', priority: 'p1', labels: ['infra', 'db'], milestone: 'launch'),
      item('T-2', status: 'in-progress', priority: 'p0', labels: ['ui']),
      item('T-3', status: 'done', priority: 'p0', milestone: 'launch'),
      item('T-4', status: 'backlog', priority: 'p3', dependsOn: ['T-2']),
    ]);

    List<String> ids(ViewResult result) => result.items.map((i) => i.id.value).toList();

    test('filter expressions: AND of entries, or, not, exists, computed fields', () {
      ViewResult run(String filter) => ViewEngine.evaluate(
        parseViewYaml('v', 'filter:\n${filter.split('\n').map((l) => '  $l').join('\n')}'),
        snapshot,
      );
      expect(ids(run('milestone: launch\nstatus: {not: [done]}')), ['T-1']);
      expect(ids(run('labels: db')), ['T-1']);
      expect(ids(run('or:\n  - labels: ui\n  - priority: p3')), ['T-2', 'T-4']);
      expect(ids(run('milestone: {exists: false}')), ['T-2', 'T-4']);
      expect(ids(run('blocked: true')), ['T-4']);
      expect(ids(run('ready: true')), ['T-1']);
      expect(ids(run('not: {category: [done, active]}')), ['T-1', 'T-4']);
    });

    test('kanban groups by workflow statuses and counts hidden items', () {
      final result = ViewEngine.evaluate(
        parseViewYaml('board', 'layout: kanban\ngroup_by: status\ncolumns: [todo, in-progress]'),
        snapshot,
      );
      expect(result.definition.layout, ViewLayout.kanban);
      expect(result.groups.map((g) => g.key), ['todo', 'in-progress']);
      expect(result.groups.map((g) => g.items.length), [1, 1]);
      expect(result.hidden, 2);
    });

    test('grouping without columns follows the workflow and adds an empty-value group', () {
      final byStatus = ViewEngine.evaluate(parseViewYaml('s', 'group_by: status'), snapshot);
      expect(byStatus.groups.map((g) => g.key), Workflow.standard().statuses.map((s) => s.id));
      final byMilestone = ViewEngine.evaluate(parseViewYaml('m', 'group_by: milestone'), snapshot);
      expect(byMilestone.groups.map((g) => g.key), ['launch', '']);
    });

    test('sorts by keys, descending with a dash', () {
      final result = ViewEngine.evaluate(parseViewYaml('s', 'sort: [-priority, id]'), snapshot);
      expect(ids(result), ['T-4', 'T-1', 'T-2', 'T-3']);
    });

    test('rejects unknown layouts and operators', () {
      expect(() => parseViewYaml('v', 'layout: pie'), throwsA(isA<ConfigurationException>()));
      expect(() => parseViewYaml('v', 'filter: {status: {like: x}}'), throwsA(isA<ConfigurationException>()));
    });
  });
}
