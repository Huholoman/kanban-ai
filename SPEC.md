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

In this order: `-C/--dir`, `$BACKLOG_DIR`, then from the current folder upwards the first folder that contains `backlog.yaml` or has a `backlog/` subfolder containing it. The second rule lets every sibling worktree find a shared `../backlog`.

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
```

Semantics:

- **Status categories** drive behaviour: `open` = not started, `active` = being worked on, `done` = finished (any done-category status, e.g. `cancelled`, counts as finished for dependencies).
- **Pickable status** — the open status agents take work from (`todo`). `claim` moves an item to the first `active` status; `release` returns an active item to the pickable status.
- **Priorities** are ordered; the first is the most urgent. They rank items inside a milestone.
- **Milestones** play the role of versions/releases; when the list is non-empty, `lint` warns about unknown ones.
- **Types** are labels; the hierarchy comes from `parent`, not from the type. `epic` is special only in the UI (epic filter, the default Board view hides epics).
- **Statuses are the board columns.** Add, rename or reorder them here; each view chooses which to show with `columns:` (§6), also editable from the app.
- **Appearance** only affects the web board: the palette is generated from `seed` per brightness, `primary`/`secondary`/`background` override parts of it; status, priority, type and label colours replace the built-in ones (columns, card stripes, tags). Invalid colours or modes are configuration errors.
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
- `updated` is set to today on every change made through the tool.

### 3.1 Derived state (computed, never stored)

| Field | Meaning |
|---|---|
| `category` | category of the status (`open`/`active`/`done`), null for an unknown status |
| `blocked` | not done, and some `depends_on` item is not done or does not exist |
| `blocked_by` | those unfinished/missing dependencies |
| `ready` | in the pickable status, not blocked, no open children, and no live claim (expired claims do not count) |
| `children` | `{total, open}` — items whose `parent` is this one |
| `progress` | checklist `{done, total}` from the body |
| `claim` | current claim with `expired` flag |
| `has_children`, `claimed`, `claimed_by` | for views and filters |

Default order ("most urgent first"): priority, then `created`, then id.

## 4. Claims — parallel work without collisions

A claim is an agent's exclusive, time-limited lock on an item, stored as `.locks/<id>.lock` (JSON: item, agent, claimed_at, heartbeat_at, expires_at).

- **claim** — atomic create of the lock file; of two agents racing for one item exactly one wins, the other gets a conflict (exit 3). Claiming also sets `assignee` and moves an open item to the active status. Blocked items and items with open children need `--force`.
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
| `init [folder] [--prefix X]` | create `backlog.yaml`, `items/`, `views/` (default views), `docs/`, `.gitignore` |
| `new <title> [-t type] [-s status] [-p priority] [-m milestone] [--parent id] [-d id,…] [--related id,…] [-l label,…] [--doc name] [--assignee a] [--branch b] [--pr url] [--body md \| --body-file f]` | create an item, prints it |
| `list [-a] [-s status] [-m milestone] [-l label] [-t type] [-w cond]…` | open items (all with `-a`), most urgent first |
| `show <id>` | item with relations (parent, children, dependencies, dependents, related), claim and body |
| `path <id>` | file path of the item |
| `set <id> <change>…` | change fields: `status=review`, `labels+=infra`, `depends_on-=X-7f3a`, `milestone=` (empty clears); unknown keys become custom fields |
| `ready [-w cond]` | items that can be started now |
| `blocked` | unfinished items waiting for others |
| `next [--as a] [-w cond]` | claim the most urgent ready item; exit 2 when there is none |
| `claim <id> [--as a] [--force]` | take an item |
| `heartbeat <id> [--as a]` | extend the claim |
| `release <id> [--as a] [--status s] [--force]` | give it back unfinished |
| `done <id> [--as a] [--status s] [--force]` | finish it |
| `claims` | who works on what |
| `view [name]` | run a saved view; without a name list views grouped by section |
| `lint` | check the backlog; exit 1 on errors |
| `instructions` | print the workflow guide for agents (Markdown, for CLAUDE.md / AGENTS.md) |

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

All front-matter keys (`id`, `title`, `type`, `status`, `priority`, `milestone`, `parent`, `depends_on`, `related`, `assignee`, `branch`, `pr`, `labels`, `docs`, `created`, `updated`), the computed `ready`, `blocked`, `claimed`, `claimed_by`, `category`, `has_children`, `ancestors` (parent chain, cycle-safe), `epic` (epics among the item and its ancestors — `epic: X` selects everything under epic X), and any custom key.

### 6.3 Grouping

Without `columns`, groups come from the workflow (statuses, priorities, types, milestones, categories in their configured order), then other present values alphabetically, then "(none)". With `columns`, other matching items are counted as `hidden`.

Default views from `init`: **Board** (kanban by status, epics hidden), **Ready to pick up**, **What's on fire** (p0/p1 not done), **Blocked**, **Dependencies** (graph).

## 7. Validation — `lint`

Errors and warnings with a code, item and location:

`unreadable` (broken file / front matter), `duplicate-id`, `file-name`, `unknown-status`, `unknown-priority`, `unknown-type`, `unknown-milestone`, `dangling-reference` (parent/depends_on/related to a missing item), `self-reference`, `dependency-cycle`, `parent-cycle`, `invalid-view`, `expired-claim`, `stale-claim`, `orphan-claim`.

## 8. Server — `backlog-server`

| Option | Env | Default | |
|---|---|---|---|
| `-C`, `--dir` | `BACKLOG_DIR` | located as in §1.1 | backlog folder |
| `--host` | | `0.0.0.0` | addresses to bind, repeatable or comma-separated (e.g. `127.0.0.1,10.77.1.2`) |
| `-p`, `--port` | | `8640` | |
| `--allow` | `BACKLOG_ALLOW` | everyone | client IPs / CIDR ranges allowed; others get 403 |
| `--token` | `BACKLOG_TOKEN` | none | require `Authorization: Bearer <t>` or `?token=` on `/api/` |
| `--generate-token` | | | random 22-char token, printed at start inside the URLs |
| `--web` | `BACKLOG_WEB` | built app next to the sources / bundled in Nix | static web app |
| `-q` | | | no request log |

At start it prints the board URLs (with the token). It watches the folder (debounced, ignoring `.git`, temp and editor files) and pushes change events; edits from agents, `git pull` or an editor appear on the board immediately. `backlog.yaml` changes reload the workflow.

### 8.1 REST API

| Method & path | Body / query | Returns |
|---|---|---|
| `GET /api/health` | — (no token needed) | `{"ok": true}` |
| `GET /api/workflow` | | statuses, priorities, types, milestones, defaults, appearance |
| `GET /api/items` | `?all=true` includes done | items (same shape as `backlog --json list`) |
| `POST /api/items` | `{title, type?, status?, priority?, milestone?, parent?, depends_on[], labels[], body}` | detail (201) |
| `GET /api/items/<ref>` | | `{item, parent, children[], dependencies[], dependents[], related[]}` |
| `PATCH /api/items/<ref>` | `{changes: ["status=done", "labels+=ui"], body?}` | detail |
| `POST /api/items/<ref>/claim` \| `release` \| `done` | `{agent?, status?, force}` | detail |
| `GET /api/views` | | `[{id, name, layout, group_by, section}]` |
| `POST /api/views` | `{name, section?, base?, conditions: [...]}` | view summary (201); writes `views/<slug>.yaml` (unique id) copying `layout`, `group_by`, `columns`, `sort`, `fields` from `base` and setting `filter: {and: [<base filter>, ...conditions]}`; invalid filters are `invalid_input` |
| `GET /api/views/<id>` | | `{id, name, layout, group_by, fields, columns, hidden, groups: [{key, items}]}` |
| `PATCH /api/views/<id>` | `{section?, columns?}` — only given keys change, null/blank/empty removes | view summary; writes `section:` / `columns:` into the YAML, keeping the rest |
| `GET /api/lint` | | `[{severity, code, message, item?, location?}]` |
| `WS /api/events` | `?token=` | `{"type": "changed", "paths": [...]}` |

Errors: `{"error": {"type", "message", "candidates"?}}` with `not_found` 404, `ambiguous_reference` 409, `invalid_input` 400, `claim_conflict` 409, `configuration` 500, `unauthorized` 401, `forbidden` 403. CORS is open (`*`) so the app can run from another origin.

## 9. Web board

URL parameters: `?token=…`, `&as=<name>` (agent name used when claiming from the UI, default `web`), `&server=http://…` (another API server).

**Layout** (responsive): from 900 px a left panel with views; from 1200 px detail panels next to the board; narrower windows use a view dropdown and full-screen detail.

**Left panel**
- *New item* button (dialog: title, type, status, priority, milestone, parent, labels, body).
- Saved views; views with `section` grouped under foldable section headings; the ⋮ menu of a view moves it to an existing or new section (persisted to the YAML).

**Filter bar** (client-side, on any view, kept across views)
- Search in id, title, branch (280 px, `/` focuses it).
- **Filters** button with a badge (number of selected values) opens a popover: Labels (own search box when there are many, count per value), Epic (everything under the chosen epic at any depth), Type, Priority, Milestone, People (assignee or claim holder); "Clear all", "N items match" and **Save as view...**. Values in one section are alternatives; sections, readiness segments and search combine with AND.
- Segmented control Ready | Blocked | Claimed (with explanatory tooltips), then one removable chip per facet with values (`label: infra`, `priority: p0-p1`). "N of M shown · Clear" when a filter is active.
- **Save as view:** turns the filter into view conditions (search → `or` of `contains` on id/title/branch, facet sections → field lists, people → `assignee` or `claimed_by`, epic → `epic`, segments → `ready/blocked/claimed: true`) and saves the current view plus them as a new view (name, optional section, optionally pinned to the mobile bottom bar); the board then switches to it with the filter cleared.
- Status is intentionally not a filter: views show it as columns.

**Kanban**
- The whole board scrolls as a page (draggable scrollbars, horizontal scroll when columns overflow); columns grow with their cards. Each column has a header (name, count) above a grey well with the cards; columns share the width, 196–280 px each.
- On a phone the columns become sections one under another (status header with count, full-width cards; empty sections hidden), without drag and drop.
- Drag a card to another column to set the field the view groups by (status, priority, type, milestone, assignee); optimistic update, rolled back with a message on failure.
- Inside a column children are indented under their parent; a parent sitting in another column appears as a muted line "↑ Epic title", so a story in progress still shows its epic.
- Parents with nested items have a fold toggle ("N hidden").
- Cards: id (click copies it) and priority on top (the most urgent one in the warning colour), the title, and one meta line by state, in this order: *● Ready*, *Blocked by …*, claim holder with the time left (*◉ agent · 1h left*), *Claim expired · agent* (faint, dashed border), otherwise labels, milestone and assignee; a PR link and branch share the line. A thin bar shows checklist or children progress. The selected card has an accent border, done cards are dimmed.

**Lists / table / graph**
- Items grouped by the view's `group_by` (headers like column headers, rows are the same cards); the graph layout shows each item with an expandable tree of its dependencies (titles, statuses, cycle-safe), clickable.

**Detail**
- Header: type, id (click copies), Claim / Release / Done actions.
- Editable title, status, priority, type, milestone, assignee, branch, pull request, labels, Markdown body (rendered, with an editor).
- PR shown as "PR #42", opens in a new tab (http/https only).
- Relations as foldable sections with counts — Children (with "x/y done"), Parent, Depends on, Blocks, Related; empty ones hidden; links added from the *Link:* row and removed with ×.
- **Panel trail:** opening a child (or any link) from a panel opens it in a new panel to the right; the child open on the right is highlighted in its parent's list. Two panels fit beside the board; with more, the board and the oldest panels give way to a breadcrumb (*Board › Epic › …*) leading back. Esc closes the rightmost panel.

**Other**
- Columns button in the app bar (views with `group_by`): pick and reorder the shown groups, saved as `columns:`; *Default* removes it.
- Theme switch system → light → dark (for the session; default from `appearance.mode`); colours from `appearance`, reloaded live.
- Lint badge in the app bar with the list of problems linking to items.
- Live updates over the WebSocket (debounced refresh), reconnecting automatically.

## 10. Installation and operation

- **Per project with mise** (recommended): `[plugins] nix = "https://github.com/jbadeau/mise-nix.git"` and `[tools] "nix:kanban-ai" = "github+Huholoman/kanban-ai#kanban-ai"` (optionally pinned `…/kanban-ai/<commit>#kanban-ai`); update with `mise install --force nix:kanban-ai`.
- **Nix flake**: `nix run github:Huholoman/kanban-ai`, `#server`; packages `kanban-ai` (CLI + server with the web bundled) and `web`; `overlays.default`.
- **NixOS module** `services.kanban-ai`: `enable`, `package`, `backlog`, `user`, `host` (string or list, default `127.0.0.1`), `port` (8640), `allow` (list), `tokenFile` (`BACKLOG_TOKEN=…`), `openFirewall`; runs a systemd service.
- **Without Nix**: Dart ≥ 3.8 and Flutter ≥ 3.32; `dart compile exe` the two entry points, `flutter build web` the app.

Agents get the workflow from `backlog instructions` (paste into CLAUDE.md / AGENTS.md): identify with `BACKLOG_AGENT`, `backlog next` or `claim`, `heartbeat` during long work, set `branch`/`pr`, `done` or `release`, split discovered work into new items, `lint` before stopping.

## 11. Architecture (for contributors)

Dart pub workspace (`backlog_core`, `backlog_cli`, `backlog_api`, `backlog_server`) plus the Flutter app outside it.

- **backlog_core** — hexagonal modules `workflow`, `items`, `claims`, `planning`, `views`, `validation`; pure `domain/`, use cases in `application/`, file-system adapters in `infrastructure/`; `Backlog` is the composition root; derived state lives in `BacklogSnapshot`.
- **backlog_cli** — thin adapter; text and JSON renderers.
- **backlog_api** — DTOs, `BacklogApi` interface, `HttpBacklogApi` (pure Dart, compiles for the web).
- **backlog_server** — shelf: `ApiHandler` + `DtoMapper`, `ChangeFeed` (watcher → WebSocket), middleware (token, client allowlist, CORS), multi-address binding.
- **backlog_app** — features `board` and `item`, each with `application/` (ChangeNotifier controllers and pure logic: `BoardFilter`, `ColumnArrangement`, `DetailTrail`) and `presentation/`; depends only on `BacklogApi`.

Development: `mise run check` (format check, analysis, all tests), `mise run playground` (demo backlog), `mise run serve`.

## 12. Known limits

- Prototype; formats may still change.
- Claims coordinate agents sharing one filesystem; agents on different machines need a shared backlog folder (or the server).
- The web app has no user accounts; protection is the token plus `--host`/`--allow`.
- Filter state, folded columns and the panel trail are not kept across page reloads.
- `section` and `columns` are the only view properties editable from the app; other view changes, statuses and colours are made in the YAML.
- The theme switch is not remembered across page reloads.
