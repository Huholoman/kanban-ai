import '../../views/infrastructure/yaml_views.dart';
import '../../workflow/infrastructure/yaml_workflow.dart';
import '../domain/init_preset.dart';

/// The presets that come with kanban-ai, in the order they are listed;
/// `default` is what `backlog init` writes without `--preset`.
final List<InitPreset> builtInPresets = [
  InitPreset(
    name: 'default',
    description:
        'The general template: backlog/todo/in-progress/review/done, priorities, types, '
        'dispatcher commented out.',
    config: workflowTemplate(idPrefix: r'${prefix}'),
    views: defaultViews,
  ),
  const InitPreset(
    name: 'minimal',
    description: 'A personal to-do list: todo/in-progress/done, no milestones, no dispatcher.',
    config: _minimalConfig,
    views: _minimalViews,
  ),
  const InitPreset(
    name: 'agents',
    description:
        'Coding agents like kanban-ai itself: review status, versions as milestones (+ later), '
        'a manual dispatcher with its own worktrees, a guide for CLAUDE.md / AGENTS.md.',
    config: '$_agentsConfig$_agentsDispatcher',
    views: _agentsViews,
    agentsGuide: _agentsGuide,
  ),
  const InitPreset(
    name: 'agents-review',
    description: 'agents plus an AI review on entering review and a local merge button.',
    config: '$_agentsConfig$_agentsDispatcher$_reviewActions',
    views: _agentsViews,
    agentsGuide: _agentsGuide,
  ),
];

const _minimalConfig = r'''
# Backlog configuration (preset minimal). Items live in items/, saved views
# in views/. See `backlog init --preset default` for every option.

id:
  prefix: ${prefix}      # new items get ids like ${prefix}-7f3a
  length: 4

# Board order. category: open | active | done
statuses:
  - id: todo
    category: open
    pickable: true
  - id: in-progress
    category: active
  - id: done
    category: done

# From the most urgent.
priorities: [p1, p2, p3]

types: [task, bug, idea]

defaults:
  status: todo
  priority: p2
  type: task
''';

const _minimalViews = {
  'board': '''
name: Board
layout: kanban
group_by: status
columns: [todo, in-progress, done]
sort: [priority, created]
''',
  'open': '''
name: Open
layout: list
filter:
  category: {not: [done]}
sort: [priority, created]
''',
};

const _agentsConfig = r'''
# Backlog configuration (preset agents). Items live in items/, saved views in
# views/. Work is done by people and coding agents in git worktrees; see
# `backlog init --preset default` for every option.

id:
  prefix: ${prefix}      # new items get ids like ${prefix}-7f3a
  length: 4

# Board order. category: open | active | done
# pickable: agents may take items in this status as ready work.
statuses:
  - id: backlog
    category: open
  - id: todo
    category: open
    pickable: true
  - id: in-progress
    category: active
  - id: review
    category: active
  - id: done
    category: done
  - id: cancelled
    category: done

# From the most urgent.
priorities: [p0, p1, p2, p3]

types: [task, story, epic, bug, decision, idea]

# Versions are milestones: the version says by when, the priority only the
# order within it. later is the pile of ideas; new items there stay in
# backlog, items of a version get status todo.
milestones:
  - id: v0.1
    title: First version
  - id: later
    title: Later

defaults:
  status: backlog
  priority: p2
  type: task

claims:
  lease_minutes: 240   # a claim without heartbeat expires after this
''';

const _agentsDispatcher = r'''
# AI agents from the board (Start agent, actions). Agents get their own
# worktrees next to the primary clone (${repo_name}-agent-<n>), never the ones
# people work in. manual: the board proposes, a person starts.
dispatcher:
  mode: manual
  repo: ${repo}        # the primary clone, relative to this folder
  base: main
  worktree_name: "${repo_name}-agent-{n}"
  max_worktrees: 2
  agent: claude
''';

const _reviewActions = r'''
  actions:
    # An AI review whenever an item enters review (also a button there); it
    # ends with backlog review --ok|--changes, shown on the card.
    - name: AI review
      review: true
      on_enter: review
      # auto_fix: 2       # on changes wake the item's agent to fix them, at most 2 rounds
      # A column of its own: add the status ai-review (category active) before
      # review above, then on_enter: ai-review and then: review — agents hand
      # over to ai-review and the review moves the item on to review for you.
    - name: Merge
      statuses: [review]
      run: merge
  # The built-in merge: rebase onto base, run the check, fast-forward base;
  # pushing base stays with a person.
  merge:
    strategy: local
    # check: [mise, run, check]   # your project's check, run after the rebase
    push: false
''';

const _agentsViews = {
  ...defaultViews,
  'epics': '''
name: Epics
layout: list
filter:
  type: epic
  category: {not: [done]}
group_by: milestone
sort: [priority, created]
''',
  'v0.1': '''
name: v0.1 – First version
section: Milestones
layout: kanban
filter:
  milestone: v0.1
  type: {not: [epic]}
group_by: status
columns: [todo, in-progress, review, done]
sort: [priority, created]
''',
};

const _agentsGuide = r'''
## Backlog

Work on ${project} is planned in a kanban-ai backlog (Markdown files, ids
`${prefix}-…`); the `backlog` CLI finds it from any worktree.

- At the start of a session run `backlog instructions` and follow them.
- Use the name of your worktree as the agent name:
  `export BACKLOG_AGENT=$(basename $(git rev-parse --show-toplevel))` (or `--as <worktree>`).
- Change status, claims and relations (claim, status, parent, depends_on, done, release) only
  through the CLI, never by editing item files; tick checklists with `backlog check <id> <n>`.
  Edit by hand only the body of an item (context, plan, notes).
- Versions are milestones (`backlog.yaml`): every new item except epics gets `-m <version>`;
  `later` is the pile. Priority (`p0`–`p3`) only orders work within a version.
- Create newly found work as a new item (`backlog new …` with the right `--parent`) instead of
  growing the current one.
- Every commit message contains the item id, e.g. `Export to CSV (${prefix}-7f3a)`.
- Before ending the session run `backlog lint` (no errors).
''';
