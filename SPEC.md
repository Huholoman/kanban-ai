# kanban-ai — specification

Status: prototype. This document describes what the tool does today (commit after `7b2b06f`); `README.md` is the quick tour, this is the reference.

## 1. Purpose and model

kanban-ai is a backlog for several coding agents (and humans) working in parallel, typically one agent per git worktree. The backlog is a plain folder of Markdown files with YAML front matter, so it can be versioned in git, edited by hand and read by any tool. On top of it there are:

- **`backlog`** — a CLI for agents and people (all commands have `--json`),
- **`backlog-server`** — a REST + WebSocket API that also serves the web board,
- **the web board** — a Flutter web app (kanban, lists, dependency tree, editable detail).

Everything derived (ready, blocked, progress, …) is computed from the files on every read; there is no database and no cache to get out of sync.

```
<project>/
  backlog/                ← the backlog (often its own git repo)
    backlog.yaml          ← workflow configuration
    items/<id>-<slug>.md  ← one file per item
    views/<id>.yaml       ← saved views
    docs/                 ← longer documents items can link to
    .locks/               ← claim locks (machine-local, git-ignored)
  monorepo/, monorepo-2/, …  ← worktrees; the CLI finds ../backlog from any of them
```

### 1.1 Locating the backlog

In this order: `-C/--dir`, `$BACKLOG_DIR`, then from the current folder upwards the first folder that contains `backlog.yaml` or has a `backlog/` subfolder containing it. The second rule lets every sibling worktree find a shared `../backlog`. `backlog-server` prefers the project registry (§1.2) to the last rule, see §8.

### 1.2 Project registry

One machine usually has several backlogs (one per project). The registry lists them for `backlog-server` (§8), which hosts all of them at once and picks up edits of the file live. It is a YAML file, by default `$XDG_CONFIG_HOME/kanban-ai/projects.yaml` (`~/.config/kanban-ai/projects.yaml` without `XDG_CONFIG_HOME`), elsewhere with `$BACKLOG_PROJECTS` or `--projects <file>`:

```yaml
projects:
  - id: kanban-ai                  # optional: slug of the project folder
    name: kanban-ai                # optional: the project folder's name
    path: ~/p/kanban-ai/backlog    # absolute, ~/… or relative to this file
  - path: ~/p/hobbyo/backlog       # → id hobbyo
```

- **Project folder** is the backlog folder itself, or its parent when the folder is called `backlog` (`~/p/hobbyo/backlog` → `hobbyo`).
- **id** — lower-case letters, digits, `-`, `_`, starting with a letter or digit; unique within the registry (a repeated or invalid id makes the whole file invalid). It appears in URLs (`/api/p/<id>/…`).
- **Order** matters: the first project is the *default project*.
- **pinned** — optional `true`/`false` (default false), read and written back; meant for clients that offer pinned projects first (not used yet).
- Unknown keys and comments are kept; `backlog init` and `backlog projects add/remove` edit the file in place. A missing file is an empty registry.

## 2. Configuration — `backlog.yaml`

```yaml
id:
  prefix: X        # ids look like X-7f3a
  length: 4        # random part from 23456789abcdefghjkmnpqrstuvwxyz; random so that parallel agents never clash

statuses:          # board order
  - id: backlog
    category: open           # open | active | done
  - id: todo
    category: open
    pickable: true           # agents may take items in this status as ready work
  - id: in-progress
    category: active
  - id: review
    category: active
  - id: done
    category: done
  - id: cancelled
    category: done

priorities: [p0, p1, p2, p3]           # most urgent first
types: [task, story, epic, bug, decision, idea]
milestones: []                         # empty = any name allowed
#  - id: launch
#    title: Production launch
#    due: 2026-12-01

defaults:
  status: backlog
  priority: p2
  type: task

claims:
  lease_minutes: 240                   # a claim without heartbeat expires after this

appearance:                            # optional; colours "#rrggbb" (quoted!), "#rgb" or without "#"
  mode: system                         # system | light | dark
  light: {seed: "#3f51b5"}             # also primary, secondary, background
  dark: {seed: "#8c9eff"}
  statuses: {todo: "#1e88e5"}
  priorities: {p0: "#e53935"}
  types: {epic: "#6a1b9a"}
  labels: {infra: "#00897b"}

dispatcher:                            # optional; without it there is no dispatcher
  mode: manual                         # manual (propose, a person starts) | auto (start by itself)
  max_agents: 2                        # at most this many at once; default one per worktree
  worktrees:                           # in order of preference
    - name: monorepo-2                 # also the agent name of its claims
      path: ../monorepo-2              # absolute, or relative to the backlog folder
    - monorepo-3                       # bare name = {name: monorepo-3, path: ../monorepo-3}
  repo: ../monorepo                    # optional: add worktrees from this primary clone when none is free (§8.2)
  worktree_name: "{repo}-{n}"          # name of added worktrees (default); next to repo, first unused n from 2
  max_worktrees: 4                     # listed + added (with repo; default max_agents)
  cleanup_after_days: 14               # remove added ones idle this long when nothing is lost (default: keep)
  base: main                           # new branches agent/<id> start from here (default main)
  agent: claude                        # agent profile (default claude): built-in or from agents
  agents:                              # optional own profiles (may replace a built-in one)
    my-claude:
      command: claude -p {prompt} --model sonnet   # string (split like a shell) or list of arguments
      env: {MY_VAR: "{worktree}"}      # extra environment, placeholders allowed
      output: claude-stream-json       # text (default) | claude-stream-json | json-lines
      resume: --resume {session}       # optional: arguments appended to continue a session
  prompt: |                            # optional; shared by all profiles, fills {prompt}
    Work on backlog item {id}, run backlog show {id} first.
  resume_prompt: |                     # optional; the prompt when an agent continues its session
    Continue on {id}. Since your last run: {news}
  actions:                             # optional: buttons on items and status hooks (§8.2)
    - name: Fix PR comments            # unique; the button's label, the name in the API and CLI
      statuses: [review]               # items in these statuses show the button (default below)
      prompt: "Go through the unresolved comments of PR {pr}, fix them, push and answer them."
      # agent: claude                  # profile (default: agent above)
      # fresh: false                   # true: a new session instead of the item's own
    - name: AI review
      on_enter: review                 # runs by itself, once, when an item enters review
      fresh: true
      prompt: "Review {branch} against {base}; write the findings with backlog comment {id}."
    - name: Merge
      on_enter: deploy
      run: merge                       # a built-in action by name (built in now: noop)
    - name: Tests
      statuses: [review]
      run: [sh, -c, "mise run check"]  # a command: a list of arguments, placeholders allowed
  pr:                                  # optional; agents push their branch and open a pull request (§5 `pr`)
    remote: origin                     # default origin
    create: 'tea pulls create --head {branch} --base {base} --title "{id}: {title}" --description-file -'
    find: 'gh pr list --head {branch} --json url --jq ".[0].url"'   # optional: URL of an open PR of the branch
    url_pattern: 'https://\S+/pulls/\d+'   # optional; group 1 or the match is the URL (default: first http(s) URL)
    merge: tea pulls merge --style rebase {pr_number}   # optional: how `run: merge` merges the PR (gh: gh pr merge --rebase {pr})
    state: gh pr view {pr} --json state --jq .state      # optional: merged | closed | open; notices PRs merged elsewhere (§8.2)
    state_every: 2                     # minutes between two state checks of an item (default 2)
  merge:                               # optional; the built-in action merge (§8.2)
    strategy: local                    # pr (default with pr) | local (default without) | command
    check: mise run check              # local: run after the rebase; a failure stops the merge
    push: false                        # local: push the merged base to remote
    remote: origin                     # default pr.remote, else origin
    # command: [./ship.sh, "{branch}"] # strategy command: merges by itself, exit code 0 = merged
    cleanup: true                      # afterwards remove the branch, a created worktree and the session (default)
  # legacy: command: claude -p "Work on {id}"  (instead of agent; a plain profile, output text)
```

Semantics:

- **Status categories** drive behaviour: `open` = not started, `active` = being worked on, `done` = finished (any done-category status, e.g. `cancelled`, counts as finished for dependencies).
- **Pickable status** — the open status agents take work from (`todo`). `claim` moves an item to the first `active` status; `release` returns an active item to the pickable status.
- **Priorities** are ordered; the first is the most urgent. They rank items inside a milestone.
- **Milestones** play the role of versions/releases; when the list is non-empty, `lint` warns about unknown ones.
- **Types** are labels; the hierarchy comes from `parent`, not from the type. `epic` is special only in the UI (epic filter, the default Board view hides epics).
- **Statuses are the board columns.** Add, rename or reorder them here; each view chooses which to show with `columns:` (§6), also editable from the app.
- **Appearance** only affects the web board: the palette is generated from `seed` per brightness, `primary`/`secondary`/`background` override parts of it; status, priority, type and label colours replace the built-in ones (columns, card stripes, tags). Invalid colours or modes are configuration errors.
- **Dispatcher** hands ready items to agents running in the listed worktrees. A worktree is *free* when no live claim is held under its name; at most `max_agents` of the listed worktrees are busy at once. **Agent profiles:** `agent` names the profile to start (default `claude`); built in are `claude` (`claude -p {prompt} --output-format stream-json --verbose --permission-mode acceptEdits --permission-prompts none --allowedTools "Bash(backlog *) Bash(git *) Bash(mise run *) Bash(./*) Read Edit Write Grep Glob TodoWrite" --disallowedTools "Bash(git push *) Bash(git -*) Bash(git send-pack *) Bash(git config *alias*)"`, output `claude-stream-json`, resume `--resume {session}`; verified with Claude Code 2.1, runs on the subscription login — never `--bare`, never `--dangerously-skip-permissions`; the deny list also covers pushes behind git's global options such as `git -C . push`, which `Bash(git push *)` alone lets through, `git send-pack` and aliases) and the unverified presets `codex` (`codex exec --full-auto --json {prompt}`, `json-lines`), `gemini` (`gemini --approval-mode auto_edit -p {prompt}`) and `aider` (`aider --yes-always --message {prompt}`). `agents: {name: {command, env, output, resume}}` defines more profiles or replaces built-in ones (`command` required; `env` a map of variable → value; `output` `text` | `claude-stream-json` | `json-lines`, default `text`; `resume` the arguments appended to the command to continue an earlier session, `{session}` being its id — only used with `claude-stream-json`, the one output a session id is read from, §8.2). **Resume prompt:** `resume_prompt` replaces `prompt` when an agent continues its session on the item; it has the prompt's placeholders and `{news}` (how the last run ended — `your last run exited with code 1; it left in-progress, released and held.` — and either `No new comments in the discussion.` or the new comments of others, each with its heading line); the default says that the agent continues item {id} on {branch}, gives `{news}`, asks it to look at the item again, then: when the comments only ask something, to answer with `backlog comment` and stop without changing code or status; when they answer its question or ask for changes, to reply briefly and go on under the same rules; to update the description or acceptance criteria above `## Discussion` when the discussion changed the assignment; and to ask again with `backlog ask` when still unclear. **Prompt:** `prompt` is one template shared by all profiles; the default tells the agent its name ({worktree}) and item, to run `backlog instructions` and `backlog show {id}` first, to commit on the prepared branch `{branch}` in small commits containing the id, to finish with `backlog set {id} status=review`, never to push, to ask with `backlog ask {id} "…"` and stop when something is unclear (comments with `backlog comment`), and to update the description or acceptance criteria above `## Discussion` when a discussion changes the assignment. With `pr` set, the default `prompt` replaces "never push" by: finish by writing a pull request description (what and why, how it was verified, that it implements {id}) and running `backlog pr {id} --description "…"`, then `backlog set {id} status=review`; never run `git push`, push other branches or merge — `backlog pr` is the only way out (when it fails, say so with `backlog comment` and still set review); the default `resume_prompt` likewise says to finish with `backlog pr {id}` (it pushes; a description only when there is no pull request yet). **Pull requests:** `pr.create` (required) and `pr.find` are commands like the agent's (string or list, no shell) with the placeholders `{id}`, `{title}`, `{branch}`, `{base}`, `{remote}`, `{description}`; `remote` must not start with `-` or contain spaces; `url_pattern` is a regular expression (its first group, else the whole match, is the URL; terminal colour codes are removed first). Without `pr` nothing pushes or opens pull requests. The legacy `command` (instead of `agent`) is a plain profile with output `text`. Commands are split into arguments like a shell would (quotes, backslashes) but never run through one, so pipes or variables need an explicit `[sh, -c, "…"]`; `{id}`, `{title}`, `{worktree}`, `{path}` (absolute worktree path), `{backlog}` (absolute backlog path) and `{branch}` (the branch prepared for the agent, §8.2) are replaced in the prompt, every command argument and `env` value, `{prompt}` (the rendered prompt) in commands and `env`; `{{`/`}}` are literal braces. The agent runs inside the worktree folder with `BACKLOG_AGENT=<worktree>`, `BACKLOG_DIR=<backlog>` and the profile's `env` added to the server's environment. **Worktrees on demand:** with `repo` (the primary clone, absolute or relative to the backlog folder) the dispatcher also creates worktrees by itself when none is free, up to `max_worktrees` in all (listed plus created; defaults to `max_agents`, which then defaults to `max_worktrees`); `worktree_name` (placeholders `{repo}` = folder name of the clone, `{n}` required) names them, `cleanup_after_days` lets it remove idle ones (§8.2). `worktrees` may then be left out. Unknown keys and placeholders, both `agent` and `command`, an unknown `agent`, a profile without `command`, an unknown `output`, invalid variable names, missing `worktrees` (without `repo`), `repo` without a limit, `worktree_name`, `max_worktrees` or `cleanup_after_days` without `repo`, a `worktree_name` without `{n}` or giving an invalid name, `max_worktrees` below the number of listed worktrees, `cleanup_after_days` < 1, duplicate names or paths, names other than `[A-Za-z0-9._-]`, a `base` starting with `-`, `max_agents` < 1 and a `mode` other than `auto`/`manual` are configuration errors; `lint` warns about worktree paths that are not folders (`dispatcher-worktree`), a `repo` that is not a folder (`dispatcher-repo`), an agent program not on the `PATH` and unverified presets (`dispatcher-agent`), and a `pr.create`/`pr.find` program not on the `PATH` (`dispatcher-pr`); unknown keys of `pr`, a missing `create`, unknown placeholders, an invalid `remote` or `url_pattern`, a `state_every` below 1 are configuration errors. `pr.merge` and `pr.state` have the placeholders `{id}`, `{title}`, `{branch}`, `{base}`, `{remote}`, `{pr}` (the item's `pr` URL) and `{pr_number}` (the last number in that URL). **Merging** (`dispatcher.merge`, used by the built-in action `merge`, §8.2): `strategy` is `pr` (merge the pull request with `pr.merge`), `local` (rebase, `check`, fast-forward, optionally `push`) or `command` (an own `command`); the default is `pr` when `dispatcher.pr` is set, else `local`. `check` and `command` are commands like the others with the placeholders `{id}`, `{title}`, `{branch}`, `{base}`, `{remote}`, `{pr}`, `{pr_number}`, `{worktree}`, `{path}`, `{backlog}`; `remote` defaults to `pr.remote`, else `origin`; `cleanup` (default `true`) removes the item's branch, the worktree the dispatcher created for it and its agent session after a merge. Configuration errors: unknown keys, an unknown `strategy`, `command` without strategy `command` (and the other way round), `check` or `push` with another strategy than `local`, a non-boolean `push`/`cleanup`, an invalid `remote`, and — when a `run: merge` action or the `merge` section exists — strategy `pr` without `pr.merge`. `lint` warns (`dispatcher-pr`, `dispatcher-merge`) when a program of `pr.merge`, `pr.state`, `merge.check` or `merge.command` is not on the `PATH`. The running server plans with it and starts the agents (§8.2).
- **Actions** (`dispatcher.actions`, optional list): each has a `name` (unique, not empty, no `/`), exactly one of `prompt` (an agent: optional `agent` profile, default `dispatcher.agent`, and `fresh: true` for a new session instead of the item's own) and `run` (a list of arguments is a command; a single name is a built-in action, currently only `noop`, which does nothing — `merge` follows), optionally `on_enter: <status>` (a hook: it runs by itself whenever an item enters that status) and `statuses` (the statuses whose items show it as a button; default every status, or only the `on_enter` status when that is set; `[]` makes a pure hook). Placeholders: a `prompt` has those of `dispatcher.prompt` plus `{pr}`, `{status}`, `{base}`, `{action}` and `{news}` (as in `resume_prompt`, or `This is a new session.`); a command has `{id}`, `{title}`, `{branch}`, `{pr}`, `{status}`, `{worktree}` (empty in the primary clone), `{path}` (where it runs), `{backlog}`, `{base}` and `{action}`. Configuration errors: unknown keys and placeholders, a missing or duplicate name, both or neither of `prompt` and `run`, an unknown built-in (`run: "make test"` is refused: commands are lists), unknown statuses in `on_enter`/`statuses`, an unknown `agent`, `agent`/`fresh` on a non-prompt action, a `fresh` that is not a boolean. `lint` warns (`dispatcher-action`) about an action's program not on the `PATH`, an unverified preset as its agent and an action that can never run (no `on_enter`, `statuses: []`). How they run: §8.2.
- Changes to `backlog.yaml` are picked up by a running server (and the board's theme) without restart.

## 3. Items — `items/<id>-<slug>.md`

```markdown
---
id: X-7f3a               # required, immutable
title: Production DB backups   # required, non-empty
type: task
status: todo
priority: p0
milestone: launch
parent: X-m4an           # epic/story it belongs to
depends_on: [X-2c91]     # hard prerequisites — they block
related: [X-a004]        # context only, never blocks
assignee: monorepo-2     # set by claims
branch: feat/backups
pr: https://github.com/org/repo/pull/42
labels: [infra, db]
docs: [backups]          # names of files in docs/
touches: [deploy/backup/, "scripts/*.sh"]   # paths/globs in the code repository the work changes (§3.2)
created: 2026-10-29
updated: 2026-10-29
estimate: 3d             # any unknown key is kept and can be filtered on
---

## Context
...
- [x] pick a tool
- [ ] tested restore     ← checklist progress is computed from these
```

Rules:

- **Ids** are `<prefix>-<random>`. Anywhere an id is expected, an unambiguous shortening works (`7f3a`, `X-7f`); an ambiguous one is an error listing the candidates.
- **File name** is `<id>-<slug-of-title>.md`; the slug strips diacritics (`Zürich DB backups` → `zurich-db-backups`). `lint` reports files whose name does not match.
- **Writing preserves the file:** comments, key order and unknown keys are kept, only changed keys are rewritten (YAML editing, not re-serialisation), so git diffs stay minimal. Writes are atomic (temp file + rename).
- **Body** is free Markdown. Checkboxes `- [ ]` / `- [x]` give the checklist progress.
- **Discussion** is the section from a `## Discussion` heading (outside code fences) to the next level-1 or level-2 heading or the end of the body. Each comment starts with a heading line `### <author> · <YYYY-MM-DD HH:MM:SS> UTC` (seconds and ` UTC` optional when written by hand), followed by ` · question` for a question or ` · note` for a note (a comment that neither answers a question nor wakes the item's agent, §8.2; headings without a marker are plain comments, as before); its text runs to the next comment heading (text before the first one is ignored; fences are never structure). `backlog comment` / `ask` (and `POST /api/items/<ref>/comments`) append a comment at the end of the section, or a new section at the end of the body, with a blank line around; headings of level 1–3 in the text become level 4, everything else in the body stays byte for byte. Authors lose line breaks, `·` becomes `-`; empty text or author is refused. Example:

  ```markdown
  ## Discussion

  ### monorepo-2 · 2026-10-31 14:05:12 UTC · question

  CSV or JSON for the export?

  ### tobik · 2026-10-31 14:20:03 UTC

  CSV.
  ```
- `updated` is set to today on every change made through the tool.

### 3.1 Derived state (computed, never stored)

| Field | Meaning |
|---|---|
| `category` | category of the status (`open`/`active`/`done`), null for an unknown status |
| `blocked` | not done, and some `depends_on` item is not done or does not exist |
| `blocked_by` | those unfinished/missing dependencies |
| `conflicting` | open (not started), has `touches`, and they overlap the `touches` of an item in an `active` status (§3.2) |
| `conflicts_with` | those active items — the item waits for them ("waits for X") |
| `needs_human` | not done, and the discussion has an open question: a `question` comment with no later comment by another author (notes do not count) |
| `ready` | in the pickable status, not blocked, not conflicting, not `needs_human`, no open children, and no live claim (expired claims do not count) |
| `children` | `{total, open}` — items whose `parent` is this one |
| `progress` | checklist `{done, total}` from the body |
| `claim` | current claim with `expired` flag |
| `has_children`, `claimed`, `claimed_by` | for views and filters |

Default order ("most urgent first"): priority, then `created`, then id.

### 3.2 Touches — which files the work changes

`touches` lists paths or globs relative to the root of the code repository (not the backlog) that the work is expected to change. It answers one question: can two items hit the same file? Matching therefore errs on the side of an overlap:

- A pattern also covers everything below what it matches, as in `.gitignore`: `lib/foo`, `lib/foo/` and `lib/foo/**` are the same. Only a last segment that looks like a file name (a dot after its first character: `pubspec.yaml`, `*.dart`) without a trailing `/` stands for files alone.
- `*` and `?` match within one segment, `**` any number of segments (also none), `{a,b}` lists alternatives (commas inside braces do not split list values in `set`/`--touches`), `[...]` counts as any one character, `\` escapes.
- A leading `/` or `./`, empty and `.` segments are ignored; matching is case-sensitive.
- Two items overlap when some path is covered by a pattern of each. An item without `touches` overlaps nothing.

**Waiting for overlapping work.** An item in an `open` status whose `touches` overlap those of an item in an `active` status (in progress, review, … — the status counts, not the claim) is `conflicting` and waits for it, like a blocked item waits for its dependencies: it is not `ready`, so `next` (and a dispatcher built on `ready`) does not start it, and `claim` refuses it without `--force`. It becomes ready by itself when the active item is done, cancelled or released back to an open status. Active items never wait; two active items that overlap are a `touches-overlap` lint warning. Unlike `blocked`, this is not stored in a relation and does not need a cycle check: it only goes from open to active items.

`lint` warns (`invalid-touches`) about an unclosed `[` or `{`, a stray `}`, a trailing `\`, `..` segments and patterns covering the whole repository (`**`, `*`, `.`).

## 4. Claims — parallel work without collisions

A claim is an agent's exclusive, time-limited lock on an item, stored as `.locks/<id>.lock` (JSON: item, agent, claimed_at, heartbeat_at, expires_at).

- **claim** — atomic create of the lock file; of two agents racing for one item exactly one wins, the other gets a conflict (exit 3). Claiming also sets `assignee` and moves an open item to the active status. Blocked items, items waiting for overlapping work (§3.2) and items with open children need `--force`.
- **heartbeat** — extends the lease (`lease_minutes`). Without heartbeats the claim **expires**; an expired claim can be taken over by another agent (atomic move-aside, again exactly one winner).
- **release** — drops the claim, returns an active item to the pickable status (or `--status`).
- **done** — sets a done-category status (default the first one, or `--status cancelled`), drops the claim, prints what got unblocked.
- Touching someone else's claim needs `--force`.
- `lint` reports `expired-claim`, `stale-claim` (lock on a finished item) and `orphan-claim` (lock for a missing item).
- Locks are machine-local (git-ignored): agents sharing one backlog folder coordinate through the filesystem.

Agent identity: `--as <name>` or `$BACKLOG_AGENT` (typically the worktree name).

## 5. CLI — `backlog`

Global options: `-C/--dir <folder>`, `--json` (machine-readable output; JSON fields are only ever added, never renamed or removed), `-h/--help`.

| Command | What it does |
|---|---|
| `init [folder] [--prefix X] [--no-register]` | create `backlog.yaml`, `items/`, `views/` (default views), `docs/`, `.gitignore`, and register the backlog in the project registry (§1.2) unless it is there already or `--no-register` is given (no registry location — no `HOME`, `XDG_CONFIG_HOME` or `BACKLOG_PROJECTS` — skips it; a broken registry only warns); JSON `{root, project?: {id, name}}` |
| `new <title> [-t type] [-s status] [-p priority] [-m milestone] [--parent id] [-d id,…] [--related id,…] [-l label,…] [--doc name] [--touches glob,…] [--assignee a] [--branch b] [--pr url] [--body md \| --body-file f]` | create an item, prints it |
| `list [-a] [-s status] [-m milestone] [-l label] [-t type] [-w cond]…` | open items (all with `-a`), most urgent first |
| `show <id>` | item with relations (parent, children, dependencies, dependents, related, the active items it waits for and the open items it holds up through `touches`), claim and body; JSON items always have `needs_human`, details also `discussion: [{author, at, text, question}]` |
| `path <id>` | file path of the item |
| `set <id> <change>…` | change fields: `status=review`, `labels+=infra`, `depends_on-=X-7f3a`, `touches+=lib/a/`, `milestone=` (empty clears); unknown keys become custom fields |
| `ready [-w cond]` | items that can be started now (`list -w conflicting=true` shows the ones waiting for overlapping work) |
| `blocked` | unfinished items waiting for others |
| `next [--as a] [-w cond]` | claim the most urgent ready item; exit 2 when there is none |
| `claim <id> [--as a] [--force]` | take an item |
| `heartbeat <id> [--as a]` | extend the claim |
| `release <id> [--as a] [--status s] [--force]` | give it back unfinished |
| `done <id> [--as a] [--status s] [--force]` | finish it |
| `claims` | who works on what |
| `comment <id> <text…> [--as a] [--note]` | add a comment to the item's discussion (§3); author `--as`, `$BACKLOG_AGENT` or `$USER`; text `-` reads stdin; JSON is the item detail (comments have `question` and `note`). `--note`: only a note — it does not answer an open question and does not wake the item's agent (§8.2) |
| `ask <id> <text…> [--as a]` | the same as a `question`: the item needs a person (§3.1) until someone else comments |
| `action <id> [<name>] [--as a]` | without a name: the actions the item's status offers (`dispatcher.actions`, §2) and the hooks it would trigger; JSON `[{name, kind, offered, on_enter, statuses, agent, fresh}]`. With a name: checks that the status offers it and writes a request into `.locks/actions/` (machine-local, like claims) for the running server's dispatcher, which starts it (or notes in the discussion why it could not, §8.2); the CLI starts nothing itself. JSON `{requested, item, action}` |
| `pr <id> [--description text \| --description-file f\|-]` | needs `dispatcher.pr` (§2), runs in the item's git worktree: the branch is the item's `branch` field, else the checked-out one; refuses `dispatcher.base`. Pushes it with `git push --set-upstream -- <remote> refs/heads/<b>:refs/heads/<b>` (never forced). When the item's `pr` is set it stops there (`created: false`); else `find` (when configured) may name an open pull request, which is recorded; else `create` runs in the worktree with the description on stdin (given text — with `Backlog item: <id>` appended when it does not name the item — or, without one, the title, `Backlog item: <id>` and the commits `base..branch`), and the URL from its output (`url_pattern`) goes into `pr`. A failed push, a failing `create` (its last output lines in the error) or no URL in its output exit 1 and leave `pr` empty. JSON `{url, created, branch, base, remote}` |
| `view [name]` | run a saved view; without a name list views grouped by section |
| `lint` | check the backlog; exit 1 on errors |
| `instructions` | print the workflow guide for agents (Markdown, for CLAUDE.md / AGENTS.md) |
| `projects [list] [--projects f]` | the project registry (§1.2): id, name, path, the default project and why a backlog cannot be opened; JSON `[{id, name, path, default, error}]` |
| `projects add [path] [--id i] [--name n]` | register a backlog (default: the one found as in §1.1; a given folder may also be the project folder with `backlog/` inside); it must open; without `--id` the derived id gets `-2`, `-3`, … when taken; the entry is written with its `id` |
| `projects remove <id>` | unregister a backlog (its files stay) |

`--where` conditions: `field=a,b` (any of), `field!=a`, `field~text` (contains, ignoring case), `field?` (has a value), `!field?` (has none); repeatable (AND). Any field from §3 / §6.2 works, including custom keys.

Exit codes: `0` ok, `1` failure / lint errors, `2` nothing to do (`next`), `3` claim conflict, `4` not found or ambiguous id, `64` usage error. With `--json`, errors are printed as `{"error": {"type", "message", "candidates"?}}`.

## 6. Views — `views/<id>.yaml`

```yaml
name: Launch board
section: Releases          # optional heading in the app's view list
layout: kanban             # list | kanban | table | graph
filter:
  milestone: launch
  category: {not: [done]}
  or:
    - priority: [p0, p1]
    - labels: security
group_by: status           # any field; items with several values (labels) appear in each group
columns: [todo, in-progress, review, done]   # groups shown and their order
sort: [priority, -updated] # - = descending
fields: [estimate]         # extra fields for cards/tables
```

### 6.1 Filter grammar

A mapping is an AND of its entries; `and: [...]`, `or: [...]`, `not: <expr>` combine expressions; `field: value` or `field: [a, b]` matches any of the values; `field: {in: [...]}`, `{not: [...]}`, `{exists: true|false}`, `{contains: text}` (substring of any value, ignoring case) refine it.

### 6.2 Fields

All front-matter keys (`id`, `title`, `type`, `status`, `priority`, `milestone`, `parent`, `depends_on`, `related`, `assignee`, `branch`, `pr`, `labels`, `docs`, `touches`, `created`, `updated`), the computed `ready`, `blocked`, `conflicting`, `conflicts_with`, `claimed`, `claimed_by`, `needs_human`, `category`, `has_children`, `ancestors` (parent chain, cycle-safe), `epic` (epics among the item and its ancestors — `epic: X` selects everything under epic X), and any custom key.

### 6.3 Grouping

Without `columns`, groups come from the workflow (statuses, priorities, types, milestones, categories in their configured order), then other present values alphabetically, then "(none)". With `columns`, other matching items are counted as `hidden`.

Default views from `init`: **Board** (kanban by status, epics hidden), **Ready to pick up**, **What's on fire** (p0/p1 not done), **Blocked**, **Dependencies** (graph).

## 7. Validation — `lint`

Errors and warnings with a code, item and location:

`unreadable` (broken file / front matter), `duplicate-id`, `file-name`, `unknown-status`, `unknown-priority`, `unknown-type`, `unknown-milestone`, `dangling-reference` (parent/depends_on/related to a missing item), `self-reference`, `dependency-cycle`, `parent-cycle`, `invalid-touches` (warning, §3.2), `touches-overlap` (warning: two active items with overlapping `touches`), `invalid-view`, `expired-claim`, `stale-claim`, `orphan-claim`, `dispatcher-worktree` (a dispatcher worktree path is not a folder), `dispatcher-agent` (warning: the agent's program is not on the `PATH`, or the profile is an unverified preset), `dispatcher-action` (warning: an action's program is not on the `PATH`, its agent is an unverified preset, or it can never run).

A broken `backlog.yaml` (including the `dispatcher` section) is not a lint issue: every command, `lint` included, fails with the configuration error (exit 1).

## 8. Server — `backlog-server`

One server hosts several backlogs (*projects*): either every project of the registry (§1.2), or a single backlog folder.

| Option | Env | Default | |
|---|---|---|---|
| `-C`, `--dir` | `BACKLOG_DIR` | | serve only this backlog folder |
| `--projects` | `BACKLOG_PROJECTS` | `$XDG_CONFIG_HOME/kanban-ai/projects.yaml` if it exists | serve the projects of this registry |
| `--host` | | `0.0.0.0` | addresses to bind, repeatable or comma-separated (e.g. `127.0.0.1,10.77.1.2`) |
| `-p`, `--port` | | `8640` | |
| `--allow` | `BACKLOG_ALLOW` | everyone | client IPs / CIDR ranges allowed; others get 403 |
| `--token` | `BACKLOG_TOKEN` | none | require `Authorization: Bearer <t>` or `?token=` on `/api/` |
| `--generate-token` | | | random 22-char token, printed at start inside the URLs |
| `--web` | `BACKLOG_WEB` | built app next to the sources / bundled in Nix | static web app |
| `-q` | | | no request log |

**What is served**, first match wins: `--dir` (one folder; given together with `--projects` it wins and a note is printed), `--projects`, `$BACKLOG_DIR`, `$BACKLOG_PROJECTS`, the default registry file when it exists, the backlog found from the current folder (§1.1) as one folder. An explicitly given registry (`--projects`, `$BACKLOG_PROJECTS`) must exist; with nothing found the server exits with 4.

- **One folder** behaves as before the registry: the backlog must open or the server does not start; it is the default project and the only entry of `/api/projects` (id derived as in §1.2).
- **Registry**: only a malformed registry stops the start. A project whose folder is missing or whose `backlog.yaml` is broken is still listed, with its `error` in `/api/projects`; its requests fail with that error (`not_found` 404 without `backlog.yaml` or folder, `configuration` 500 for a broken one) and it recovers by itself once fixed (a missing folder is retried on every request). The registry file is watched: projects added, removed, renamed or reordered apply without a restart (a removed project stops its watcher and dispatcher and closes its event sockets); a malformed edit is logged and ignored, the previous projects keep running.

At start it prints the projects (id, path, the default one, errors), the web app and the board URLs (with the token). The web app is served with `Cache-Control: no-cache` and an ETag per file (derived from the build's location, size and time — files in the Nix store all share one date), so browsers revalidate and never keep files of an older build. Each project's folder is watched (debounced, ignoring `.git`, temp and editor files) and its change events go to its own WebSocket; edits from agents, `git pull` or an editor appear on the board immediately. `backlog.yaml` changes reload that project's workflow.

**Item cache.** The files stay the only source of truth; the server keeps the parsed item files of each project in memory so that a request does not parse every file again. Every request that needs the items (lists, details, views, lint, the dispatcher) still lists `items/` and `stat`s each file, and parses again only files that are new or whose stamp changed; deleted and renamed files drop out. A file's stamp is its modification time, change time (ctime) and size; a cached file is reused only when the stamp is unchanged **and** both times were more than 3 s older than the moment the file was read. File times have a coarse resolution (milliseconds, 2 s on FAT), so a file rewritten within the same tick with the same size keeps its stamp; such recently changed files are therefore read again on every request until they settle (and parsed only if their text differs). Restoring an old modification time (`touch -r`, `rsync -t`) still changes the ctime. Writes through the API drop the written file from the cache. Guarantees: a request answers from the files as they are when it starts, whoever changed them (API, CLI agents, editors, `git checkout`), without depending on the watcher; claims (`.locks/`) are read fresh on every request and derived state (blocked, ready, expired claims) is computed with the current time; an edit of `backlog.yaml` reopens the project and drops its cache; each project has its own cache. Not covered: a change that keeps size, modification time and ctime (only possible by changing the clock or with file systems that do not maintain ctime). The CLI reads all files every time (a short-lived process).

### 8.1 REST API

Every path below except `/api/health` and `/api/projects` exists per project under `/api/p/<id>` (`/api/p/hobbyo/items`, `WS /api/p/hobbyo/events`, …); the unprefixed paths address the **default project**, the first one of the registry. An unknown `<id>` is `not_found` 404, and with no project at all so are the unprefixed paths. The token, `--allow` and CORS apply to all paths alike.

| Method & path | Body / query | Returns |
|---|---|---|
| `GET /api/health` | — (no token needed) | `{"ok": true}` |
| `GET /api/projects` | | `[{id, name, path, error}]` in registry order; `error` (why the backlog cannot be opened) is null for working projects |
| `GET /api/workflow` | | statuses, priorities, types, milestones, defaults, appearance, `actions: [{name, kind, statuses, on_enter, agent, fresh}]` (`dispatcher.actions`; `kind` `prompt` \| `command` \| `builtin`, `statuses` null for the default, `agent` the profile of a prompt action) |
| `GET /api/items` | `?all=true` includes done | items (same shape as `backlog --json list`) |
| `POST /api/items` | `{title, type?, status?, priority?, milestone?, parent?, depends_on[], labels[], touches[], body}` | detail (201) |
| `GET /api/items/<ref>` | | `{item, parent, children[], dependencies[], dependents[], related[], conflicts[], waiting[], discussion[], actions[]}` — `actions`: those its status offers as buttons (shape as in the workflow); `conflicts`: active items it waits for, `waiting`: open items waiting for it (§3.2), `discussion`: the comments `[{author, at, text, question}]` (§3); items carry `needs_human` (§3.1) |
| `PATCH /api/items/<ref>` | `{changes: ["status=done", "labels+=ui"], body?}` | detail |
| `POST /api/items/<ref>/claim` \| `release` \| `done` | `{agent?, status?, force}` | detail |
| `POST /api/items/<ref>/comments` | `{text, author?, question?, note?}` | adds a comment to the discussion (§3; author default: the server's `$USER`, else `web`); detail (`discussion[]` items have `question` and `note`). With a resumable agent session this is a reply that resumes it (§8.2), unless `note: true` |
| `POST /api/items/<ref>/actions/<name>` | — (`name` URL-encoded) | starts the action now, in either mode (§8.2); the new plan. `not_found` without a dispatcher or for an unknown action, `invalid_input` when the item's status does not offer it, `unavailable` when something already runs for the item, no worktree is free (prompt) or a command has nowhere to run, `claim_conflict` when a prompt action finds the item claimed |
| `GET /api/views` | | `[{id, name, layout, group_by, section}]` |
| `POST /api/views` | `{name, section?, base?, conditions: [...]}` | view summary (201); writes `views/<slug>.yaml` (unique id) copying `layout`, `group_by`, `columns`, `sort`, `fields` from `base` and setting `filter: {and: [<base filter>, ...conditions]}`; invalid filters are `invalid_input` |
| `GET /api/views/<id>` | `?group_by=field` regroups for this request only (empty: ungrouped; columns dropped) | `{id, name, layout, group_by, fields, columns, hidden, groups: [{key, items}]}` |
| `PATCH /api/views/<id>` | `{section?, columns?}` — only given keys change, null/blank/empty removes | view summary; writes `section:` / `columns:` into the YAML, keeping the rest |
| `GET /api/lint` | | `[{severity, code, message, item?, location?}]` |
| `GET /api/dispatch` | | the dispatcher's plan (§8.2): `{configured, mode, agent, max_agents, running, capacity, worktrees: [{name, path, busy, free, claims[], unavailable, created, new, run: {item, worktree, pid, started_at, log, agent, branch}}], assignments: [{item, title, worktree, resume, new_worktree}], waiting: [ids], held: [{item, title, reason}], sessions: [{item, session_id, worktree, ended_at, reason}], max_worktrees, spare_worktrees}` — `resume`: the session the assignment continues (null: a new one); `sessions`: unfinished items whose last session the configured agent can continue (its worktree still exists); `created`: the dispatcher made the worktree, `new`/`new_worktree`: it will be created when the assignment starts (never with `resume`), `max_worktrees`: null without `repo`, `spare_worktrees`: how many it may still create; `runs`: everything running (`{item, worktree, pid, started_at, log, agent, branch, action, kind}` — agents, also those of prompt actions, and the commands and built-ins of actions, in a worktree or in the primary clone; `kind` `agent` \| `command` \| `builtin`, `action` null for the item's own agent; the same object is `worktrees[].run`); `pending_actions: [{item, action, status, since}]` — `on_enter` actions waiting to run; `{configured: false, …}` without a `dispatcher` section |
| `POST /api/dispatch/start` | `{item, fresh?}` | starts an agent for the ready item, in either mode (lifts a hold): it continues the item's last session in that session's worktree when it can (§8.2), unless `fresh: true`; else a new session in the first free worktree (or a new one, §8.2); the new plan. `invalid_input` when not ready, `claim_conflict` when claimed or someone was faster, `unavailable` when no worktree is free or it cannot be prepared |
| `POST /api/dispatch/stop` | `{item}` | stops its agent (§8.2); the new plan; `not_found` when none runs |
| `GET /api/dispatch/log/<ref>` | `?lines=100` (1–2000) | `{item, path, running, lines[], last: {exit_code, reason, outcome, ended_at, session_id}}` — the tail of the running agent's log, else of its last run; `not_found` when no agent ran |
| `WS /api/dispatch/log/<ref>/live` | `?lines=200` (1–2000), `?token=` | follows the agent log of the item like `tail -f` (checked every 0.5 s): messages `{"type": "agent-log", item, path, running, reset, lines[], last}`. The first one (`reset: true`) carries the last `lines` readable lines of the running agent's log, else of the last run (read from at most the last 512 KiB), or `path: null` and no lines while no agent has run; then each message carries the lines appended since (only complete lines while the agent runs), a change of `running` (with `last` once it ended), or `reset: true` with the tail of a new run's log. Lines are readable rather than raw: for `claude-stream-json` the assistant's text, one `▸ <tool> <command or path>` line per tool call, `  ✗ <tool>: …` for failed tool results and denied permissions, `! rate limit: …` when limited, `● Claude Code <version> · <model> · session <id>` at the start and `■ done · N turns · S s · $cost · session <id>` (or `■ failed (…)`) at the end; other JSON events (tool output, …) are left out, lines that are not JSON (the launcher's `# kanban-ai:` lines, stderr) pass through. Other outputs come as they are. `not_found` (no upgrade) for an unknown item or a project without a running dispatcher |
| `WS /api/events` | `?token=` | `{"type": "changed", "paths": [...]}` on file changes; `{"type": "dispatch", "paths": []}` when the dispatcher's plan changed (agent started or ended, worktree became busy, free or unavailable, …) |

Errors: `{"error": {"type", "message", "candidates"?}}` with `not_found` 404, `ambiguous_reference` 409, `invalid_input` 400, `claim_conflict` 409, `unavailable` 409 (e.g. no free worktree), `configuration` 500, `unauthorized` 401, `forbidden` 403. CORS is open (`*`) so the app can run from another origin.

### 8.2 Dispatcher

Every project runs its own dispatcher. With a `dispatcher` section in its `backlog.yaml` (§2) the server keeps a dispatch plan for it: after every change event (debounced again by 500 ms) and whenever a live claim expires (that frees a worktree or an item without touching a file) it takes a snapshot and computes

- **busy worktrees** — those with a live claim under their name or with an agent process still running in them; claims of other agents do not occupy worktrees and do not count against `max_agents`,
- **unavailable worktrees** — not busy, but no agent can start there: the folder is missing, it is not a git worktree, or `git status --porcelain` is not empty (uncommitted changes or untracked files). They are not free; the plan is evaluated again every 30 s while one is unavailable (worktrees are not watched),
- **replies** — unfinished, unclaimed items without a running agent and without an open question whose last agent session the configured agent can continue (see *Continuing a session*), with comments in the discussion written after that run started by anyone but the agent (its worktree name), notes (` · note`) not counted: a person wrote to the agent,
- **assignments** — first the replies, each in its session's worktree, then ready items (§3.1) in the order of `backlog next` paired with free worktrees in the configured order (then those it created, then new ones, see below), at most `max_agents` minus the busy ones,
- **held** — ready items the dispatcher does not start by itself because their last agent ended without finishing or a person stopped it (a manual start lifts the hold),
- **waiting** — ready items left over, and replies whose session's worktree is busy or unavailable (they wait for it).

The plan is logged whenever it changes (`Dispatcher (auto): 1/2 running; starts X-7f3a → monorepo-3; held: X-2c91; monorepo-2 unavailable: uncommitted changes (2 paths).`). In `auto` mode every new assignment goes to the agent launcher once (again only after it dropped out of the plan or its launch failed); in `manual` mode nothing starts by itself. Without the section the dispatcher is idle; edits of the section apply live. `-q` also silences the dispatcher log. Served from a registry, log lines start with `[<project id>]`.

**Worktrees on demand** (`dispatcher.repo`). The worktrees of the plan are the listed ones followed by those the dispatcher created earlier, recorded in `$STATE/worktrees/<project>/<name>.json` (name, path, clone, creation and last use; a record whose folder is gone is forgotten). Folders it did not create are never adopted, even when their names fit the pattern. While listed plus created worktrees are fewer than `max_worktrees`, the plan also has *new* worktrees: the names of `worktree_name` for n = 2, 3, … that are neither listed, nor recorded, nor held by a live claim, nor the worktree of an unfinished item's last session, and whose folder next to the clone (`<parent of repo>/<name>`) does not exist — always the first unused numbers, so names and paths are deterministic. Free existing worktrees are used first; an assignment to a new worktree is shown in the plan (`new`, `new_worktree`, log: `X-7f3a → monorepo-3 (new worktree)`) and, when it starts, `git worktree add --detach <path> <base>` runs in the clone first (nothing uncommitted is carried over), then the launcher continues as below with its branch. A failed `git worktree add` starts nothing (the reason is logged and returned by a manual start).

**Cleanup** (only with `cleanup_after_days`): a created worktree that is free (no claim, no agent), clean (as above) and unused for that many days — counted from its creation, its last agent start or the last time it was seen busy — is removed with `git worktree remove` (never forced) when its checked-out commit is contained in `base` (merged, or no commits of its own); its branch is kept. Worktrees with unmerged commits stay until they are merged. A worktree that holds the last agent session of an unfinished item (see *Continuing a session*) is never cleaned up, however idle: a later start, a reply or the answer to the agent's question continues that session there and only there; it becomes eligible once the item is done (or deleted).

**Starting an agent.** The launcher (the same for every profile):

1. checks the worktree again (clean git worktree, see above; otherwise nothing starts and the reason is logged),
2. claims the item under the worktree's name — a claim conflict means someone was faster and nothing starts,
3. checks out the item's branch in the worktree: the item's `branch` field when set, else `agent/<id>`; an existing branch is switched to (a released item continues where its last agent stopped), a new one is created from `dispatcher.base` (default `main`) and recorded in the item's `branch` field. The agent does not have to manage branches; the prompt only tells it which one it is on (`{branch}`). When this fails, the claim is released and nothing starts,
4. starts the profile's command in the worktree as a **detached process** in its own session (it outlives a restart of the server), with stdin from `/dev/null`, stdout and stderr appended to `$STATE/logs/<project>/<id>-<UTC time>.log` (headed by the command), and the environment of the server plus `BACKLOG_AGENT`, `BACKLOG_DIR` and the profile's `env`,
5. records it in `$STATE/agents/<project>/<id>.json` (item, worktree, path, pid, process group, start, log, profile, output format, branch).

`$STATE` is `$KANBAN_AI_STATE_DIR`, else `$XDG_STATE_HOME/kanban-ai`, else `~/.local/state/kanban-ai`; `<project>` is the project id (§1.2). A small `sh` wrapper writes the exit code to `<id>.exit` next to the record and a closing line into the log.

**While it runs** the server checks every 5 s whether the process is alive (on Linux by `/proc/<pid>/cmdline`, which must still name the log) and renews its claim with a heartbeat every quarter of the lease (1–10 minutes). A restarted server picks the records up again, renews the claims at once and goes on watching.

**When it has ended**, the outcome depends on the item:

- still in the first active status (`in-progress`) and claimed by the worktree → **released** to the pickable status and **held** with the reason (`<id>.hold.json`), so that `auto` mode does not start it again in a loop (failures and rate limits are not retried; a person looks and starts it again),
- still in the first active status, claimed by the worktree, and the agent asked a question (`needs_human`) → only **released**, not held: it is not ready until somebody answers,
- in another status while claimed by the worktree (the agent ran `backlog set <id> status=review`) → only the **claim is dropped**; status and assignee stay. **Pull request safety net:** when that status is `active` (e.g. `review`), `dispatcher.pr` is configured, the item's `pr` is empty and its branch has commits not in `base` (`git rev-list base..branch`), the launcher does what `backlog pr` does (§5) in the worktree, with the agent's last message as the description (the `result` of a `claude-stream-json` log), else the agent's last comment, else the default description; the outcome is a ` · note` by `dispatcher` in the discussion (`… pushed agent/X-7f3a and opened <url>`, or `Could not open a pull request for …: <reason>` — the item then stays where the agent put it, `backlog pr` retries), so it wakes nobody; a branch without own commits gets a note and no pull request,
- done, released or claimed by someone else → left alone.

The record is replaced by `<id>.last.json` (exit code, reason, outcome, end time and, for `claude-stream-json`, the `session_id` of the run — a resumed run that reports none keeps the one it continued); the outcome is also appended to the log and logged by the server. Logs are kept.

**Continuing a session.** The plan knows the session of each unfinished item's last run (from `<id>.last.json`). When the profile can resume (it has `resume` and output `claude-stream-json`), the session was run by the same profile and its worktree is free, a start of the item continues it **in that worktree** (agents keep sessions per folder): the command gets the profile's `resume` arguments and the prompt is `resume_prompt` with `{news}`. Assignments of other items leave such a worktree to the item when another free worktree (or a new one) exists — for ready items and replies later in the plan, and for items whose agent asked a question that waits for an answer (`needs_human`). When the session's worktree is busy or unavailable, or the profile cannot resume, a ready item starts a new session in any free worktree. A manual start with `fresh` always starts a new session. A session never continues in a *new* worktree (§ *Worktrees on demand*): new worktrees only take new sessions, after every free existing one that no waiting session needs. **When the session's worktree is gone:** a created worktree whose folder disappeared (removed by hand; cleanup never removes it, see above) is forgotten, and with it the session — the plan no longer lists it in `sessions`, the next start of the item is a new session in any free or new worktree, and a reply on an item that is not ready (e.g. `review`) is not proposed any more until a person starts the item again (the discussion stays in the item, so the new session sees it via `backlog show`). A *listed* worktree that is missing is only unavailable (§ above), so its sessions and replies wait for it.

**Replies resume the agent.** A reply (above) is assigned like ready work, but before it, whatever the item's status (`review`, `todo` after a question, …) and even when it is held (the reply is the person's go-ahead): it always continues the session in its own worktree, and its `{news}` lists the new comments — notes written since the run included, as context (followed by `Comments marked "note" are context for you; they need no answer.`). A note alone never resumes the agent, nor does it answer its question; it only reaches the agent with the next resume for another reason (a reply, a manual start). In `auto` mode it starts by itself; in `manual` mode it is proposed and a manual start (the board's *Send and continue*) starts it, also when the item is not ready. The resumed agent answers with `backlog comment` and either stops (a question about its work) or continues (an answer to its question, a change request). Once it started, the comments are older than its session and no longer count, so nothing loops; a person's comment while it runs is picked up after it ends. The claim of a resumed item follows the usual rules: an item in `review` stays there and only loses the claim at the end. The log head and the server log say `resuming session <id>`; the record keeps it as `resumed`.

**Stopping** sends `SIGTERM` to the agent's process group (`SIGKILL` after 5 s); the item is then released and held as above ("stopped by a person"). Stopping an action's agent or command only ends it (the item keeps its status, see *Actions*); built-in actions cannot be stopped (`invalid_input`).

Two servers hosting the same project share `$STATE` and would both look after its agents; run one.

**Actions** (`dispatcher.actions`, §2) run on one item, either because a person asks (a button on the board, `POST …/actions/<name>`, `backlog action <id> <name>`; only actions the item's status offers) or as a hook (`on_enter`), in `auto` and `manual` mode alike (hooks are explicit rules; to switch one off, remove its `on_enter`). An item has at most one run at a time: while its agent or another action runs, a request fails with `unavailable` and a hook waits.

- **Prompt actions** start an agent through the launcher above, with the action's profile. The worktree: the one of the item's last session when the profile can continue it there and the action is not `fresh` (the command gets the `resume` arguments); else the free worktree that has the item's branch checked out, then the free worktree of its session, then any free (or new) one — within `max_agents`. The agent claims the item under the worktree's name **without changing the item** (status and assignee stay; done items too), the branch is prepared as usual, and the prompt is the action's text in a fixed frame: who and where the agent is, that the item stays in its status unless the action asks otherwise (never `in-progress`), the item's context (`backlog show`, or `Since your last run: {news}` when continuing) and to finish with `backlog comment` (or `backlog ask`) and stop; it never runs `git push` — with `dispatcher.pr` it publishes its commits with `backlog pr {id}`, which updates the item's pull request (e.g. after fixing review comments). At the end the claim is only dropped — never released or held, whatever the status — and a note goes into the discussion (`### kanban-ai · … · note`: `The action "AI review" (agent claude in wt-2) exited with code 0 after 3 min.`). A continued or non-`fresh` run is recorded as the item's last session (`<id>.last.json`, see *Continuing a session*); a `fresh` run is a side session recorded in `<id>.action.json` and the item keeps its own session (a reply resumes that one). An action never lifts a hold.
- **Commands** run detached like agents (same `sh` wrapper, record and log, stdin from `/dev/null`, environment of the server plus `BACKLOG_DIR`, `KANBAN_AI_ITEM`, `KANBAN_AI_ACTION` and, in a worktree, `BACKLOG_AGENT=<worktree>`), **in the free dispatcher worktree that has the item's branch checked out** (it stays busy meanwhile; uncommitted changes do not matter), else in the primary clone `dispatcher.repo` (`{worktree}` empty); with neither the command cannot run. Nothing is claimed and the item is not changed. When it has ended, a note gives the exit code, the duration and the last 20 lines of its output (in a code block). The record of the run is `<id>.action.json`.
- **Built-in actions** (`run: <name>`) run inside the server, in the same place as a command (the backlog folder when there is neither), with their own log; they cannot be stopped and a restart of the server while one runs ends it as `interrupted`. Their result (`succeeded: …` / `failed: …`) is the note. Built in: `noop` (does nothing, for trying actions and hooks out). Implementations get the item, the action, the configuration, the backlog's services, the working directory, the placeholders and a way to run programs into the log (`BuiltInAction` in `backlog_core`); every name `backlog.yaml` accepts has one.
- **Hooks (`on_enter`).** Every plan compares the status of each item with the status it had in the previous plan; an item whose status changed to an action's `on_enter` status queues that action **once per transition** (a later change back and forth queues it again). Items seen for the first time (new items, the very first plan) trigger nothing. Statuses and the queue are kept in `$STATE/actions/<project>/state.json`, so a restarted server neither repeats a hook nor forgets one queued or caused while it was down (it compares with the statuses it saw last). A queued action starts as soon as nothing runs for the item (e.g. right after the agent that moved it to `review` has ended) and, for a prompt action, the item is not claimed and a worktree is free; it is dropped when the item leaves that status first, is deleted or the action is removed. A hook that cannot start for another reason (a command without a place to run, an unknown item) is dropped with a note. In `auto` mode hooks start after the ready work of the same plan. The plan shows them in `pending_actions`; the log says `Dispatcher: X-7f3a entered review; queued the action "AI review".`
- **Requests of the CLI** wait as files in `<backlog>/.locks/actions/`; every plan takes them (oldest first) and starts them like a button; a request that cannot start leaves a note on the item (`The action "Tests" (requested by tobik) could not start: …`).

**Manual start and stop** go through the API (§8.1) and the board (§9): a start re-plans first, takes the worktree of the session it continues or else the first free worktree (even one the plan proposes for a more urgent item) and launches as above; it works in `auto` mode too. Every published plan is also sent as a `dispatch` event over the project's WebSocket.

## 9. Web board## 9. Web board

URL parameters: `?token=…`, `&as=<name>` (agent name used when claiming from the UI, default `web`), `&server=http://…` (another API server).

**Projects:** the app loads `GET /api/projects` and opens the project named by the route after `#` (`/#/p/<id>`), else the one last opened in this browser (`localStorage`, per server origin), else the first available project; unknown and unavailable projects in the URL fall back the same way. The route always names the open project (a link can be shared and reloaded) and the page title is its name. Each project gets a fresh session: its API (`/api/p/<id>/…`), theme, board, filters, open item and WebSocket; the previous project's are disposed. A URL edited to another `#/p/<id>` switches to it. When `/api/projects` answers 404 (a server without projects) the app shows the single backlog on the unprefixed paths; other failures show the error with *Retry*; when no project can be opened their errors are listed.

**Layout** (responsive): from 1200 px a left panel with views (208 px, 240 px from 2000 px) and the open item as a panel on the right; 840–1199 px view tabs under the header (☰ opens a drawer with the full navigation) and the open item as a bottom sheet; below 840 px the open item is a full page; below 600 px the header has ☰ and a view dropdown and a bottom bar shows the pinned views (up to three; the first two views when none are pinned) plus *More* (the drawer). *New item* is a floating button outside the left panel. From 2000 px wide (27" 4K and similar) text is 15 % larger.

**Left panel**
- On top the open project's name; with more than one project it opens a menu of all registered projects (the open one ticked; one the server cannot open greyed out with its error and not selectable). The drawer has the same switcher on narrower windows and phones.
- *New item* button (dialog: title, type, status, priority, milestone, parent, labels, body).
- Saved views with their item count; views with `section` grouped under foldable section headings; the ⋮ menu of a view moves it to an existing or new section (persisted to the YAML) or pins it to the phone's bottom bar.
- *People*: agents holding a live claim with how many items each holds (busiest first); a click narrows the board to that agent's items (the People filter).
- *Agents* (with a dispatcher, §8.2): heading *Agents · mode · running/max*; one row per worktree — the item its agent works on (or holds a claim on), *free* or *unavailable* (reason as tooltip) — a click opens the item; the plan's assignments (*X → w2*, with ▶ *Start* in `manual` mode), held items (reason as tooltip) and *N more ready*. Reloaded on `dispatch` events.
- *Lint* summary at the bottom ("Lint: 2 warnings"); a click lists the problems with links to items.

**Header** (56 px, top of the main area): the filter bar, then *Group: status ▾* (regroups the current view for the session by status, priority, type, milestone, assignee, labels or epic, or none; *The view's own* goes back; an asterisk marks a changed grouping; only an icon when the header is narrow), compact buttons for columns, theme and reload, and a loading indicator. `/` focuses the search when no text field has focus.

**Filter bar** (client-side, on any view, kept across views)
- Search in id, title, branch (280 px, `/` focuses it).
- **Filters** button with a badge (number of selected values) opens a popover: Labels (count per value), Epic (everything under the chosen epic at any depth), Type, Priority, Milestone, People (assignee or claim holder). A section with more than six values shows only six — the ticked ones, then the most frequent — with *Show all (N)* and its own search box, so the other sections stay in reach; Type and Priority are rows of checkboxes; "Clear all", "N items match" and **Save as view...**. Values in one section are alternatives; sections, readiness segments and search combine with AND.
- Segmented control Needs you | Ready | Blocked | Waiting | Claimed (*Needs you* = `needs_human`, §3.1) (with explanatory tooltips; *Waiting* = `conflicting`, §3.2; it scrolls sideways when too narrow), then one removable chip per facet with values (`label: infra`, `priority: p0-p1`). "N of M shown · Clear" when a filter is active.
- **Save as view:** turns the filter into view conditions (search → `or` of `contains` on id/title/branch, facet sections → field lists, people → `assignee` or `claimed_by`, epic → `epic`, segments → `needs_human/ready/blocked/conflicting/claimed: true`) and saves the current view plus them as a new view (name, optional section, optionally pinned to the mobile bottom bar); the board then switches to it with the filter cleared.
- Status is intentionally not a filter: views show it as columns.

**Kanban**
- The whole board scrolls as a page (draggable scrollbars, horizontal scroll when columns overflow); columns grow with their cards. Each column has a header (name, count) above a grey well with the cards; columns share the width, 196–280 px each.
- On a phone the board shows one column at a time, full width: swipe sideways or use the switcher on top (‹ todo · 7 › and a scrollable row of all columns with counts; the current one scrolls into view). Empty columns stay as pages ("Nothing in …"). A long press on a card opens *Move X to* with the other columns, which sets the grouped field like a drop.
- Drag a card to another column to set the field the view groups by (status, priority, type, milestone, assignee); optimistic update, rolled back with a message on failure.
- Inside a column children are indented under their parent; a parent sitting in another column appears as a muted line "↑ Epic title", so a story in progress still shows its epic.
- Parents with nested items have a fold toggle ("N hidden").
- Cards: id (click copies it) and priority on top (the most urgent one in the warning colour), the title, and one meta line by state, in this order: *? Waits for you* (`needs_human`; the card also gets a warning-coloured border), *● Ready*, *Blocked by …*, *Waits for …* (touches overlap work in progress), claim holder with the time left (*◉ agent · 1h left*), *Claim expired · agent* (faint, dashed border), otherwise labels, milestone and assignee; a PR link and branch share the line. A thin bar shows checklist or children progress. The selected card has an accent border, done cards are dimmed. When the dispatcher has actions its status offers (`dispatcher.actions`), a small *⋯* menu before the priority lists them (icon by kind: agent, command, built-in) and runs the chosen one (`POST …/actions/<name>`); it shows an hourglass while something runs for the item and the entries are disabled then.

**Lists / table / graph**
- Items grouped by the view's `group_by` (headers like column headers, rows are the same cards); the graph layout shows each item with an expandable tree of its dependencies (titles, statuses, *blocked* / *waiting* tags, cycle-safe), clickable.

**Detail**
- **Agent:** *Start agent* among the actions of a ready item when the dispatcher has a free worktree or may create one (either mode); when the item's last agent session can be continued (its worktree is free), *Continue agent* (tooltip: where) and *Start fresh* instead. Proposals in the *Agents* panel that continue a session end with ↻, those that create a worktree with *(new)*. While an agent works on the item, a box under the header shows *Agent <profile> in <worktree> since HH:MM (N min) · <branch>*, *Hide log*/*Log* and *Stop* (after a confirmation), and below them the agent's **live log** (`…/log/<ref>/live`, §8.1): readable lines (tool calls, failures and the result highlighted), at most 2000 kept, *Live · <path>* above them. The box stays at the newest line while lines arrive; scrolling up pauses that (*Paused · jump to end* resumes). The log is open while the agent runs. After the run (and for any item whose agent ran before) the box stays as *Agent · last run* with the log collapsed; opened, it shows *Last run · <reason> · <outcome> · claude --resume <session>* and the end of that log. A held item shows *Held: <reason>*.
- **Actions:** a button per action the item's status offers (`dispatcher.actions`, icon by kind, tooltip what it does) among the header's actions, disabled while something runs for the item; it runs the action (`POST …/actions/<name>`, a notice says what started or why not). The box under the header then shows *Action "AI review" · claude in wt-2 since …* (or *Action "Tests" (command) in wt-2 since …*) with its live log and *Stop* (not for built-ins; the confirmation says that the item keeps its status), and every `on_enter` action waiting for the item as *Queued: the action "AI review" (entered review at …)*. The result arrives as a note in the discussion.
- Header: back (when the detail has history), breadcrumb of the parent chain (*Epic › Story › X-2c91 Title*, ancestors clickable), close; below it "Story 2 of 5" with ‹ 2 / 5 › stepping through the parent's children (disabled at the ends, hidden without a parent; no history entry), or "Task · X-7f3a" without a parent; id (click copies), Claim / Release / Done actions.
- **Navigation inside the detail:** every link (ancestor, sibling, child, relation, blocker) shows the item in the same panel or page; ← walks back the way taken. The board resets it when another card is opened.
- "Blocked by X-7f3a Title" warning line when blocked; "Waits for X-7f3a Title (touches the same files)" when conflicting; a muted "Holds up …" line on an active item that open items wait for. The ids open in the panel.
- An epic has a *Scope board* button that narrows the board to everything under it (the Epic filter).
- Title edited in place (saved on Enter or when the field loses focus); status and priority side by side as compact dropdowns (a chip with the value's colour dot and ▾ opens the list of values); milestone, type, assignee, branch (monospace), pull request, labels (chips with × and *+ label*) and touches (monospace chips with × and *+ path*, comma-separated globs) as a definition list, each edited in place; Markdown body in a card (rendered, with an editor), its checklist items (`- [ ]` / `- [x]`, not inside code blocks) as checkboxes that rewrite their line and save the body.
- PR shown as "PR #42", opens in a new tab (http/https only).
- **Discussion** (under the description, which shows and edits the body without its `## Discussion` section — saving puts the section back after it): *Discussion · N*, each comment with author, local time, a *question* tag (*question · waits for you* in the warning colour while open) and its Markdown; a reply field (*Answer w1…* / *Write to the agent of X…* / *Add a comment…*) and *Send* (`POST …/comments`, author `&as=` or the server's default). When the dispatcher can continue the item's last agent session and no agent runs for it: in `manual` mode *Send* and *Send and continue* (comments, then starts the agent, which resumes the session with the reply, §8.2), in `auto` mode *Send: the agent continues in w1 by itself. Note only: it is not woken.* With such a session or an open question there is also *Note only* (tooltip: what it does not do), which posts the comment with `note: true`; notes show a *note* tag. An item that needs a person has a *Waits for you: w1 asked a question in the discussion below.* line under the title, its border warning-coloured, and a *waits for you* tag.
- Children ("Tasks" for a story) with "x of y done": each row (▸ id, title, status) expands in place to the first lines of the child's body, its own children ("Subtasks x of y done") and *Open X →*.
- Parent, Depends on, Blocks, Related as folded rows with counts ("Depends on 1 ▸"); empty ones hidden; links added from the *Link:* row and removed with ×.
- **One detail panel:** 480 px (520 px from 2000 px) right of the board from 1200 px; from 840 px a bottom sheet over the board (about 45 % of the height, drag handle, ⤢ opens it as a full page); narrower windows use a full page. Esc closes it.

**Other**
- Columns button in the header (views with `group_by`): pick and reorder the shown groups, saved as `columns:`; *Default* removes it.
- Theme switch system → light → dark (for the session; default from `appearance.mode`); colours from `appearance`, reloaded live.
- Live updates over the WebSocket (debounced refresh), reconnecting automatically.

## 10. Installation and operation

- **Per project with mise** (recommended): `[plugins] nix = "https://github.com/jbadeau/mise-nix.git"` and `[tools] "nix:kanban-ai" = "github+Huholoman/kanban-ai#kanban-ai"` (optionally pinned `…/kanban-ai/<commit>#kanban-ai`); update with `mise install --force nix:kanban-ai`.
- **From a clone, per user**: `mise run install [ref]` (or `tool/install.sh [ref]`, default `main`; a branch, tag or commit of the clone) builds `git+file://<clone>?rev=<sha>` with Nix, out-link `~/.local/state/kanban-ai/release` (GC root) and symlinks `backlog`, `backlog-server` in `~/.local/bin`; `mise run install-dev` (`tool/install.sh --dev`) builds the worktree as it is (uncommitted changes of tracked files included) into `…/dev` and links `backlog-dev`, `backlog-server-dev`. `KANBAN_AI_BIN_DIR`, `KANBAN_AI_STATE_DIR` override the folders (state defaults to `$XDG_STATE_HOME/kanban-ai`). Prints the ref and commit it installed.
- **Nix flake**: `nix run github:Huholoman/kanban-ai`, `#server`; packages `kanban-ai` (CLI + server with the web bundled) and `web`; `overlays.default`.
- **NixOS module** `services.kanban-ai`: `enable`, `package`, `backlog`, `user`, `host` (string or list, default `127.0.0.1`), `port` (8640), `allow` (list), `tokenFile` (`BACKLOG_TOKEN=…`), `openFirewall`; runs a systemd service.
- **Without Nix**: Dart ≥ 3.8 and Flutter ≥ 3.32; `dart compile exe` the two entry points, `flutter build web` the app.

Agents get the workflow from `backlog instructions` (paste into CLAUDE.md / AGENTS.md): identify with `BACKLOG_AGENT`, `backlog next` or `claim`, `heartbeat` during long work, set `branch`/`pr`, give new items `touches`, `done` or `release`, split discovered work into new items, `lint` before stopping.

## 11. Architecture (for contributors)

Dart pub workspace (`backlog_core`, `backlog_cli`, `backlog_api`, `backlog_server`) plus the Flutter app outside it.

- **backlog_core** — hexagonal modules `workflow`, `items`, `claims`, `planning`, `dispatch`, `views`, `validation`, `projects` (the registry: `ProjectRegistry`, port `ProjectRegistryStore`, `ProjectService`, YAML store); pure `domain/`, use cases in `application/`, file-system adapters in `infrastructure/`; `Backlog` is the composition root; derived state lives in `BacklogSnapshot`; `DispatchPlan` (pure) turns a snapshot into assignments, `Dispatcher` re-plans on changes and hands them to the `AgentLauncher` port, implemented by `ProcessAgentLauncher` (detached processes, state under `$STATE`; also the commands and `BuiltInAction`s of actions) behind `WorktreeProvisioner` (worktrees on demand: records, `git worktree add`, cleanup); actions: `ActionDefinition` (workflow), `DispatchPlan.actionStart` (where one runs), `ActionState` (status hooks, port `ActionStateStore`) and `ActionRequests` (requests of the CLI).
- **backlog_cli** — thin adapter; text and JSON renderers.
- **backlog_api** — DTOs, `BacklogApi` and `ProjectsApi` interfaces, `HttpBacklogApi`, `HttpProjectsApi` (pure Dart, compiles for the web).
- **backlog_server** — shelf: `ProjectHub` (hosted projects, `/api/p/<id>` routing, `/api/projects`) with a `HostedProject` per backlog (`BacklogHost`, `ChangeFeed` → its WebSocket and dispatcher, `ApiHandler` + `DtoMapper`), `RegistryWatcher` (live registry), middleware (token, client allowlist, CORS), multi-address binding.
- **backlog_app** — features `board`, `item`, `projects` (`ProjectsController` picks the open project; one session per project) and `dispatch` (`DispatchController`: the plan, Start, Stop and actions, shared by the board and the detail through `DispatchScope`), each with `application/` (ChangeNotifier controllers and pure logic: `BoardFilter`, `ColumnArrangement`, `DetailNavigation`; shared design tokens in `shared/tokens.dart`) and `presentation/`; depends only on `ProjectsApi` and `BacklogApi`.

Development: `mise run check` (format check, analysis, all tests), `mise run playground` (demo backlog), `mise run serve`.

## 12. Known limits

- Prototype; formats may still change.
- Overlapping `touches` are judged on one snapshot: two agents running `next` at the same moment can still take two overlapping open items (the lock is per item). `lint` then reports `touches-overlap`.
- The board shows only the tail of an agent's raw log (no parsing of `stream-json` yet, no live streaming).
- Agent processes are watched by polling (`/proc` on Linux, `kill -0` elsewhere); the launcher needs `sh`, `git` and `kill`.
- Claims coordinate agents sharing one filesystem; agents on different machines need a shared backlog folder (or the server).
- The web app has no user accounts; protection is the token plus `--host`/`--allow`.
- Filter state, folded columns and the detail's navigation history are not kept across page reloads.
- `section` and `columns` are the only view properties editable from the app; other view changes, statuses and colours are made in the YAML.
- The theme switch is not remembered across page reloads.
- The server's item cache (§8) still `stat`s every item file per request; very large backlogs pay for that, and the CLI parses every file on each run.
