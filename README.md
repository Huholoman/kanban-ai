# kanban-ai

> ⚠️ **Prototype.** It works and is tested, but it has not been used on a real project yet. The file format, CLI, API and UI may change without regard for backward compatibility. The server has no users or roles, only an optional shared token — expose it only on a trusted network (LAN, VPN).

A backlog for a project worked on by several AI coding agents in parallel (each in its own git worktree) plus a human.

- **Tasks are files.** Each item is Markdown with YAML front matter in a shared folder you can version with git. Edit it in your editor, let agents use the CLI, or use the browser.
- **The `backlog` CLI** is for agents and humans alike. It claims work without collisions (atomic locks with leases) and tracks dependencies and the epic → story → task hierarchy. It also has saved views and a linter. Output is optionally JSON, and exit codes tell agents what happened.
- **`backlog-server` and a web board** (Flutter web) offer a kanban with drag & drop, cards grouped under their epics, a side-panel detail view, editing of fields and descriptions, and a dependency tree. The board updates live when an agent changes something on disk.

```
 agents in worktrees              human in the browser
 monorepo-2 ─┐                    ┌─ http://server:8640
 monorepo-3 ─┼─ backlog (CLI) ─┐  │
 monorepo-4 ─┘                 ▼  ▼
                     backlog/  ◄── backlog-server (REST + WebSocket)
                     ├ backlog.yaml
                     ├ items/*.md      ← its own git repository
                     └ views/*.yaml
```

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [How agents use it](#how-agents-use-it)
- [The web board](#the-web-board)
- [Backlog format](#backlog-format)
- [CLI reference](#cli-reference)
- [Architecture](#architecture)
- [Development](#development)
- [Roadmap](#roadmap)

## Installation

### Per project with mise (recommended)

The backlog belongs to a project, so the tool should be pinned there too: every clone, worktree and agent then gets the same `backlog` on `PATH`. [mise](https://mise.jdx.dev) installs it from this flake through the [mise-nix](https://github.com/jbadeau/mise-nix) backend plugin. You need Nix with flakes enabled (`experimental-features = nix-command flakes`).

Add this to the project's `mise.toml`:

```toml
[plugins]
nix = "https://github.com/jbadeau/mise-nix.git"

[tools]
"nix:kanban-ai" = "github+Huholoman/kanban-ai#kanban-ai"
# pinned to a commit (recommended — the tool is a prototype):
# "nix:kanban-ai" = "github+Huholoman/kanban-ai/<commit>#kanban-ai"
```

```bash
mise install            # builds or fetches the flake package
mise exec -- backlog ready
mise exec -- backlog-server -C backlog   # the web app is bundled
```

The `github+` prefix replaces `github:`, because mise does not allow colons in versions. Alternatively, put `"nix:kanban-ai"` in the global `~/.config/mise/config.toml`.

### Nix (flake)

```bash
nix run github:Huholoman/kanban-ai -- --help              # the CLI, without installing
nix run github:Huholoman/kanban-ai#server -- -C ./backlog  # the server with the web app
nix profile install github:Huholoman/kanban-ai            # backlog + backlog-server into your profile
```

The `kanban-ai` package contains `backlog` and `backlog-server`. The web app (`packages.<system>.web`) is bundled with the server, so nothing else is needed.

**NixOS / home-manager / your system flake:**

```nix
{
  inputs.kanban-ai.url = "github:Huholoman/kanban-ai";

  outputs = { nixpkgs, kanban-ai, ... }: {
    nixosConfigurations.my-machine = nixpkgs.lib.nixosSystem {
      modules = [
        # just the package:
        { environment.systemPackages = [ kanban-ai.packages.x86_64-linux.default ]; }
        # or via the overlay: nixpkgs.overlays = [ kanban-ai.overlays.default ]; → pkgs.kanban-ai

        # optionally the server as a systemd service:
        kanban-ai.nixosModules.default
        {
          services.kanban-ai = {
            enable = true;
            backlog = "/home/me/projects/myapp/backlog";
            user = "me";                           # needs write access to the backlog folder
            host = [ "127.0.0.1" "10.77.1.2" ];    # default 127.0.0.1; 0.0.0.0 = everywhere
            allow = [ "127.0.0.1" "10.77.0.0/16" ];  # optional client allowlist
            tokenFile = "/run/secrets/kanban-ai";  # contains BACKLOG_TOKEN=…
            openFirewall = true;
          };
        }
      ];
    };
  };
}
```

With home-manager, `home.packages = [ kanban-ai.packages.${system}.default ];` is enough.

### From a clone, for your user

With the project registry one `backlog-server` serves all your backlogs, so installing the tools once for your user is enough. From a clone of this repository (Nix with flakes needed):

```bash
mise run install                # backlog, backlog-server from main
mise run install 3b0c6ec         # … or from another branch, tag or commit of the clone
mise run install-dev            # backlog-dev, backlog-server-dev from this worktree (uncommitted changes included)
```

The task builds the flake with `nix build`, keeps the result as a GC root in `~/.local/state/kanban-ai/` (`release`, `dev`) and links the binaries into `~/.local/bin`, which must be on `PATH`; it prints the ref and commit it installed. The web app is bundled. `KANBAN_AI_BIN_DIR` and `KANBAN_AI_STATE_DIR` change the two folders. Without mise: `tool/install.sh [ref]`, `tool/install.sh --dev`. The `-dev` pair lets you try a branch next to the release, e.g. a second board with `backlog-server-dev --port 8650`.

### Without Nix

You need Dart ≥ 3.8, and Flutter ≥ 3.32 for the web app.

```bash
git clone https://github.com/Huholoman/kanban-ai && cd kanban-ai
dart pub get
dart compile exe packages/backlog_cli/bin/backlog.dart -o ~/.local/bin/backlog
dart compile exe packages/backlog_server/bin/backlog_server.dart -o ~/.local/bin/backlog-server
(cd packages/backlog_app && flutter pub get && flutter build web)
# the server looks for the app in packages/backlog_app/build/web; otherwise --web <dir> or BACKLOG_WEB
```

## Quick start

```bash
cd ~/projects/myapp                    # next to the worktrees: myapp/{monorepo,monorepo-2,…}
backlog init backlog --prefix MA       # creates myapp/backlog/ and registers it for backlog-server
cd backlog && git init && git add -A && git commit -m "backlog" && cd ..

backlog new "Payments" -t epic -p p1
backlog new "Payment gateway" -t story --parent MA-xxxx -s todo
backlog new "Production DB backups" -s todo -p p0 -l infra,db
backlog list
backlog view board
backlog-server --token secret          # prints its URLs, e.g. http://192.168.1.10:8640/?token=secret
```

The backlog is found by walking up from the current folder, looking for `backlog.yaml` or a `backlog/backlog.yaml` subfolder. An agent in `myapp/monorepo-3/src/…` therefore finds `myapp/backlog/` without any configuration. Otherwise use `-C <dir>` or `BACKLOG_DIR`.

**Why a separate repository, outside the code:** worktrees are on different branches. A backlog inside the code repository would differ per branch, and agents would not see each other's claims.

### Playground

A script generates a made-up project (a bike-service booking app) with epics, stories, dependencies, work in progress and an expired claim:

```bash
tool/playground.sh                     # → playground/ (gitignored); run again to reset
backlog-server -C playground/backlog
cd playground/monorepo-2 && backlog next --as monorepo-2   # an "agent" takes work; the board updates
```

## How agents use it

Add this to the project's `CLAUDE.md` (or `AGENTS.md`):

```markdown
## Backlog
Tasks live in ../backlog and are managed with the `backlog` CLI. At the start of a session
run `backlog instructions` and follow them. Use the name of your worktree as the agent name
(`export BACKLOG_AGENT=$(basename $(git rev-parse --show-toplevel))`).
```

`backlog instructions` prints the full guide. In short:

```bash
backlog next                    # claim the most urgent ready item (exit 2 = nothing to do)
backlog show MA-7f3a            # details, dependencies, file path
backlog heartbeat MA-7f3a       # renew the claim (default lease 4 h)
backlog set MA-7f3a branch=feat/x status=review
backlog done MA-7f3a            # finished: drops the claim, prints what got unblocked
backlog release MA-7f3a         # give it back unfinished
backlog ask MA-7f3a "CSV or JSON?"   # a question for a person; then stop
backlog comment MA-7f3a "Done, see the commit."   # a note in the item's discussion
backlog lint                    # before ending the session
```

**Claims:** `claim` and `next` atomically create `.locks/<id>.lock` (O_EXCL), so when several agents race for an item exactly one wins. This is verified by a test with 12 isolates and by hand with 10 parallel processes. Without a `heartbeat` the lock expires after its lease and another agent may take the item over. The item file mirrors `status: in-progress` and `assignee`, so humans see who works on what. Locks are machine-local state (gitignored) and work on a local disk, not on network file systems.

**Ready** means the status is `pickable` (`todo` by default), all `depends_on` items are done, there are no open children, nobody holds a claim, the item's `touches` do not overlap an item in progress, and no question in it waits for a person.

**Discussion:** `backlog comment <id> "text"` and `backlog ask <id> "question"` append to a `## Discussion` section at the end of the item's body (author = `--as`, `BACKLOG_AGENT` or `$USER`; text `-` reads stdin). A question that nobody else has answered yet makes the item **need a person** (`needs_human`): it is not ready, so `next` and the dispatcher skip it, until someone answers with a comment. `backlog list -w needs_human=true` lists them; `show` says `NEEDS A PERSON`. When a discussion changes what the item asks for, the description or acceptance criteria above `## Discussion` are updated and the comments stay as the history.

**Touches keep agents apart:** an open item whose `touches` overlap the `touches` of an item in an active status (in progress, review) *waits for* it — `backlog list` shows `waits for MA-7f3a (touches overlap)`, JSON has `conflicting` and `conflicts_with`. It is not ready, so `next` skips it and `claim` needs `--force`, until the other item is done or released. Items without `touches` never wait. Two items in progress that overlap are a lint warning.

## The web board

```bash
backlog-server -C path/to/backlog --token secret   # one backlog
cd ~/p/myapp && backlog projects add               # or register every backlog once…
backlog-server --token secret                      # …and serve them all from one server
```

**Several projects:** without `-C`, the server serves every backlog of the project registry (`~/.config/kanban-ai/projects.yaml`, see `backlog projects` below) when it exists, otherwise the backlog found from the current folder. The board switches between them; the API has them under `/api/p/<id>/…` (`/api/projects` lists them) and the plain `/api/…` paths mean the first, default project. The registry is watched, so `backlog projects add/remove` apply without a restart. A project with a missing folder or a broken `backlog.yaml` does not stop the server, it is listed with its error. `-C` (or `BACKLOG_DIR`) always means just that one backlog.

To keep the board off the LAN without a firewall, bind only to localhost and the VPN interface, and/or allow only some clients:

```bash
backlog-server --host 127.0.0.1,10.77.1.2                 # listen only on these local addresses
backlog-server --allow 127.0.0.1,10.77.11.22,10.77.0.0/16  # answer only these clients
```

| Option | Default | |
|---|---|---|
| `-C`, `--dir` | `BACKLOG_DIR` | serve only this backlog folder |
| `--projects` | `BACKLOG_PROJECTS`, else `~/.config/kanban-ai/projects.yaml` if it exists, else the backlog found from the current folder | project registry to serve |
| `--host` | `0.0.0.0` | addresses to bind, repeatable or comma-separated; `127.0.0.1` = local only |
| `--allow` | `BACKLOG_ALLOW` | only these client IPs or CIDR ranges get an answer, others 403 |
| `-p`, `--port` | `8640` | |
| `--token` | `BACKLOG_TOKEN` | when set, `/api/` requires it |
| `--generate-token` | | require a random token; it is printed at start, inside the URLs |
| `--web` | `BACKLOG_WEB`, else `packages/backlog_app/build/web` | the built web app (served with ETags and `no-cache`, so browsers pick up a new build at once) |
| `-q` | | do not log requests |

URL parameters of the app: `?token=…`, `&as=name` (who claims items from the UI) and `&server=http://…` (another API server, handy with `flutter run -d web-server`).

The open project is in the URL after `#`: `http://host:8640/?token=…#/p/kanban-ai`. Such a link can be shared or reloaded; without one the app opens the project you used last in this browser, else the server's first project. The page title is the project's name. Switching projects starts the board afresh (no filters, open items or live updates carry over). With a server that does not know projects yet the app shows its one backlog as before.

**Features:**
- **Layout:** from 1200 px the views are in a left panel and the open item in a panel on the right; on tablets the views are tabs under the header and the item is a bottom sheet; on phones a bottom bar holds the pinned views. On very wide screens (from 2000 px, e.g. 27" 4K) text is 15 % larger.
- **Projects:** the project's name tops the left panel (and the drawer on tablets and phones); with several projects on the server it is a menu for switching between them. A project the server cannot open is listed with the reason and cannot be chosen.
- **Left panel:** saved views with their item counts and a button for new items. Views with a `section` are listed under foldable section headings. The ⋮ menu of a view moves it to an existing or new section, and the server writes `section:` into its YAML. Below 1200 px the views are tabs under the header (and in a drawer behind ☰); on phones a bottom bar shows the views pinned with the ⋮ menu ("Pin to bottom bar") plus *More*.
- **Cards:** id and priority on top, the title, and one meta line that tells the state: *Ready*, *Blocked by …*, *Waits for …* (touches overlap work in progress), the claim holder with the time left, an expired claim (faint, dashed border) or else the labels; a thin bar shows progress of the checklist or children.
- **Ids:** clicking an item id (on a card or in the detail) copies it to the clipboard.
- **Pull requests:** an item's `pr` link shows as a "PR #42" tag that opens it in a new tab; it can be set in the detail or by an agent (`backlog set <id> pr=<url>`).
- **Kanban:** the board scrolls as one page, columns grow with their cards and share the width. On a phone you see one column at a time and swipe (or tap the column switcher on top) to the others; a long press on a card moves it to another column. Dragging a card to another column sets the field the view is grouped by (status, priority, …). A parent with nested items in a column (an epic, a story) has a fold toggle that hides them and shows how many are hidden. Within a column, children are indented under their parent. When the parent (an epic, say) sits in another column, it appears as a muted "↑ Epic title" line above its children, so you can see which epic a story in progress belongs to.
- **Filter bar:** search (id, title, branch) and a Filters popover (long sections show the six most used values, *Show all* and a search box) for labels, epic (everything under the chosen epic, at any depth), type, priority, milestone and people (assignee or claim holder), plus the segments *Ready* (pickable status, dependencies done, no open children, nobody holds it), *Blocked* (waits for an unfinished dependency), *Waiting* (its touches overlap an item in progress) and *Claimed* (someone holds it, i.e. it is being worked on). Values within one section are alternatives; everything else must match. The filter works on any view and is kept when switching views; status is left out because views show it already. **Save as view** stores the current view plus the filter as a new view (name and optional section; the new file in `views/` keeps the layout, grouping, columns and sorting of the current view and ANDs its filter with yours).
- **Detail:** opens in a right-hand panel on wide windows, in a bottom sheet over the board on medium ones and full-screen on narrow ones (Esc closes it). You can edit all fields, labels, touches (paths or globs, as chips), relations (parent, dependencies, related), the Markdown description, and claim, release or finish the item: the title right where it is shown, status and priority from their dropdowns, the rest from the list of fields below them. Checklist items in the description are checkboxes: ticking one rewrites its `- [ ]` line in the file. The header shows the parent chain as a breadcrumb (*Launch hardening › X-2c91 Restore drill*) and the item's place among its siblings (*Story 2 of 5*, with ‹ › to step to the neighbours). Children are listed with their progress (*Tasks 1 of 3 done*); ▸ expands a child in place to the start of its description and its own children, *Open X →* shows it. A line names what the item is blocked by or waits for (overlapping touches), or which open items wait for it. Parent, depends on, blocks and related are folded rows with a count; empty kinds are left out and new links are added from the *Link:* row. Whatever you open from the detail — an ancestor, a sibling, a child, a linked item — replaces it in the same panel, and ← goes back the way you came. An epic's *Scope board* button narrows the board to everything under it. Esc closes the panel.
- **The `graph` layout** (default view "Dependencies") shows each item with an expandable tree of its dependencies, including their titles and statuses. Clicking a dependency opens its detail.
- **People:** the left panel lists the agents that hold claims right now with their item counts; a click shows what that agent works on.
- **Agents (dispatcher):** with a `dispatcher` section the left panel shows *Agents · mode · running/max*: each worktree with the item its agent works on, *free*, or *unavailable* (the reason in the tooltip, e.g. uncommitted changes), the proposed next starts (▶ starts one in `manual` mode) and held items. A ready item's detail has **Start agent** when a worktree is free (in either mode) — or **Continue agent** and **Start fresh** when its last agent session can be continued (proposals that continue a session show ↻); while an agent works on an item, its detail shows the agent, worktree, start time and branch, **Log** (the tail of its log, refreshed every 5 s) and **Stop** (terminates it; the item goes back to the queue, held). Held items show why. The plan updates live.
- **Group by:** the header's *Group: …* menu regroups the current view for the session (status, priority, type, milestone, assignee, labels, epic or none) without changing its YAML; dragging a card then sets that field.
- **Columns:** for a view grouped by a field, the columns button in the header picks which groups are shown and in what order (drag to reorder); it is saved as `columns:` in the view's YAML, *Default* removes it.
- **Theme:** light / dark / system switch in the header (for the session; the default comes from `appearance.mode`).
- **Lint:** a summary at the bottom of the left panel ("Lint: 2 warnings"); clicking it lists the problems with links to the items.
- **Live updates:** the server watches the folder and pushes changes over a WebSocket. The board shows straight away what an agent did in the CLI, what came from `git pull` and what changed in an editor. Edits of `backlog.yaml` apply without a restart.

## Backlog format

```
backlog/
  backlog.yaml                # workflow: statuses, priorities, types, milestones, id prefix, lease
  items/
    MA-7f3a-production-db-backups.md
    MA-8m2x-content-reporting/   # a folder only when the item needs attachments
      index.md
  views/   board.yaml, ready.yaml, hot.yaml, blocked.yaml, dependencies.yaml, …
  docs/    design documents that items link to (docs: [moderation])
  .locks/  claim locks (gitignored)
```

### Item

```markdown
---
id: MA-7f3a              # required, immutable; random so that parallel agents never clash
title: Production DB backups   # required
type: task               # epic | story | task | bug | decision | idea
status: todo             # as defined in backlog.yaml
priority: p0
milestone: launch
parent: MA-m4an          # the epic/story it belongs to
depends_on: [MA-2c91]    # hard prerequisites, they block
related: [MA-a004]       # context only, does not block
assignee: monorepo-2     # set by claims
branch: feat/backups
pr: https://github.com/org/repo/pull/42   # shown as a clickable "PR #42"
labels: [infra, db]
docs: [backups]
touches: [deploy/backup/, "scripts/*.sh"]   # files in the code repository the work changes
created: 2026-10-29
updated: 2026-10-29
estimate: 3d             # unknown keys are kept and can be filtered on
---

## Context
...

## Acceptance criteria
- [x] pick a tool
- [ ] tested restore         ← progress is computed from the checkboxes

## Discussion

### monorepo-2 · 2026-10-30 14:05:12 UTC · question

Restic or borg?

### tobik · 2026-10-30 14:20:03 UTC

Restic, we already use it elsewhere.
```

**Types:**
- An *epic* is a big goal spanning weeks; it is not worked on directly but groups the work.
- A *story* is a piece of functionality that makes sense to a user.
- A *task* is a concrete piece of work for one agent.
- *Bug*, *decision* and *idea* mean what they say.

The hierarchy comes from `parent`. The type is just a label, so you can define your own.

**Touches** are paths or globs in the code repository (relative to its root) that the work will change: `lib/payments/` (a folder and everything in it), `lib/**/*.dart`, `pubspec.yaml`, `{lib,test}/payments/`. Two items overlap when some file could match both; matching errs on the side of an overlap (a pattern also covers what is below it, as in `.gitignore`, unless its last part looks like a file name such as `*.dart`). `lint` warns about malformed patterns and ones that cover the whole repository.

Files may be edited by hand. When the tool writes a file, it keeps comments, key order and unknown keys and changes only what changed, so git diffs stay small. Ids can be shortened: `7f3a` or `MA-7f` is enough when unambiguous.

**The discussion** is the last section, `## Discussion`, written by `backlog comment` / `backlog ask` (and the board): one `### <author> · <date time> UTC` heading per comment, ` · question` for a question that waits for a person. It is plain Markdown, so it can be read and edited by hand (seconds and `UTC` may be left out); a comment ends at the next comment heading, the section at the next `#`/`##` heading.

Derived properties are computed, never stored: `blocked`, `conflicting` (waits for overlapping work in progress), `needs_human` (an unanswered question), `ready`, and the progress of the checklist and of the children.

### Workflow (`backlog.yaml`)

`backlog init` writes a commented file with:
- statuses `backlog`, `todo`, `in-progress`, `review`, `done` and `cancelled`
- priorities `p0`–`p3`
- types, milestones, defaults and the claim lease
- commented examples of `appearance` and `dispatcher`

Every status belongs to the category `open`, `active` or `done`. Items in the `done` category satisfy dependencies, and agents pick up work from statuses marked `pickable`. The statuses are the possible board columns; which of them a view shows, and in what order, is set by `columns:` in the view (or from the app, see below).

**Colours** of the web board go to an optional `appearance` section (quote the colours, an unquoted `#…` is a YAML comment):

```yaml
appearance:
  mode: system                 # system | light | dark — the default, the app can still switch
  light: {seed: "#3f51b5"}     # a palette is generated from the seed; optional primary, secondary, background
  dark: {seed: "#8c9eff", background: "#121212"}
  statuses: {todo: "#1e88e5", in-progress: "#fb8c00", review: "#8e24aa", done: "#43a047"}
  priorities: {p0: "#e53935", p1: "#fb8c00"}
  types: {epic: "#6a1b9a", bug: "#c62828"}
  labels: {infra: "#00897b", ui: "#d81b60"}
```

The board picks up changes to it live.

**Dispatcher** (optional): which worktrees agents may run in, how many at once, which coding agent to start and with what prompt. Without the section there is no dispatcher. A worktree is free when nobody holds a live claim under its name.

```yaml
dispatcher:
  mode: manual          # manual: a person presses Start in the board | auto: starts by itself
  max_agents: 2         # default: one per worktree
  worktrees:            # path relative to the backlog folder; a bare name means ../<name>
    - name: monorepo-2
      path: ../monorepo-2
    - monorepo-3
  base: main            # new branches agent/<id> start here
  agent: claude         # a profile; claude is the default
  agents:               # optional: own profiles, or replacements of built-in ones
    claude-sonnet:
      command: 'claude -p {prompt} --model sonnet --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools "Bash(backlog *) Bash(git *) Read Edit Write Grep Glob"'
      env: {MY_SETTING: "{worktree}"}
      output: claude-stream-json   # text | claude-stream-json | json-lines
      resume: --resume {session}   # optional: continue the item's last session
  prompt: |             # optional; the default is below
    You are {worktree}. Work on backlog item {id}: run backlog show {id} first.
  resume_prompt: |      # optional; when an agent continues its session
    Continue on {id}. Since your last run: {news}
```

**Agent profiles.** A profile is a command template, extra environment (`env`) and the format of its output. Built in:

| Profile | Command | Status |
|---|---|---|
| `claude` (default) | `claude -p {prompt} --output-format stream-json --verbose --permission-mode acceptEdits --permission-prompts none --allowedTools "Bash(backlog *) Bash(git *) Bash(mise run *) Read Edit Write Grep Glob TodoWrite" --disallowedTools "Bash(git push *)"` | verified with Claude Code 2.1 |
| `codex` | `codex exec --full-auto --json {prompt}` | unverified preset |
| `gemini` | `gemini --approval-mode auto_edit -p {prompt}` | unverified preset |
| `aider` | `aider --yes-always --message {prompt}` | unverified preset |

The `claude` profile runs Claude Code headless on your subscription login: no API key, never `--bare` (it ignores the login) and never `--dangerously-skip-permissions` — edits are accepted, a whitelist of tools is allowed, everything else is refused and `git push` is forbidden. It is also the one profile that can **resume**: its `resume` arguments (`--resume {session}`) continue an earlier session. For other tools (tests of another language, …) define your own profile. The unverified presets follow the CLIs' documentation and have not been run here; `lint` reminds you of that.

**The prompt** (`dispatcher.prompt`) is shared by all profiles and fills `{prompt}`. By default it tells the agent its name and item, to run `backlog instructions` and `backlog show {id}` first, to commit on the branch prepared for it in small commits with the item id, to finish with `backlog set {id} status=review`, never to push, when something is unclear to ask with `backlog ask` and stop, and to update the description when a discussion changes the assignment.

**Continuing a session.** Starting the same item again — after *Stop*, after an agent ended without finishing, or by hand later — continues its last agent's session instead of starting a new one, when the profile can resume (`resume:`; only `claude`, whose session id kanban-ai reads from the `claude-stream-json` output) and that session's worktree is free: the agent sessions live per folder, so it runs in the same worktree again (other items leave that worktree to it when they can). It then gets `dispatcher.resume_prompt` (default: you are continuing item {id}, `{news}` — how the last run ended —, look at the item again and go on under the same rules). Otherwise, or with *Start fresh* (`POST /api/dispatch/start {"item", "fresh": true}`), a new session starts.

**Talking to the agent of an item.** When someone other than the agent comments on an unfinished item whose last session can be continued — an answer to the agent's `backlog ask`, or a question like "why did you do it this way?" on an item in review — the dispatcher resumes that session in its worktree with the new comments in `{news}`: right away in `auto` mode, as a proposal (*Send and continue* on the board) in `manual` mode, before other work and even for held items. The default resume prompt tells the agent to answer with `backlog comment` and stop when it was only asked something, or to reply and continue the work when it got an answer or a change request, and to bring the description up to date when the discussion changed the assignment. If the session's worktree is busy, the reply waits for it.

Commands are split into arguments like in a shell, but no shell runs them (use `[sh, -c, "…"]` if you need one). Placeholders in the prompt, commands and `env`: `{id}`, `{title}`, `{worktree}`, `{path}` (absolute path of the worktree), `{backlog}`, `{branch}`; commands and `env` also `{prompt}`. The agent always gets `BACKLOG_AGENT=<worktree>` and `BACKLOG_DIR=<backlog folder>`. The older `command: …` (instead of `agent`) still works as a plain profile. Mistakes in the section are configuration errors; `lint` warns about worktree paths that do not exist, an agent command that is not on the `PATH` and unverified presets. A running `backlog-server` re-plans after every change and whenever a claim expires: ready items in the order of `backlog next` go to free worktrees, at most `max_agents` at once, and it logs the plan. In `auto` mode it starts each new assignment by itself; in `manual` mode it only proposes and a person presses *Start agent* on the board (or `POST /api/dispatch/start`).

**How an agent runs.** The server checks that the worktree is a clean git worktree (uncommitted changes or untracked files make it unavailable until cleaned up), claims the item under the worktree's name (if someone was faster, nothing starts), switches the worktree to the item's branch (its `branch` field, else `agent/<id>` created from `base` and written into the item) and starts the agent there as a detached process: it keeps running when the server restarts, and a restarted server finds it again. Its output goes to `~/.local/state/kanban-ai/logs/<project>/<id>-<time>.log`, its pid and details to `~/.local/state/kanban-ai/agents/<project>/<id>.json` (`$XDG_STATE_HOME` or `$KANBAN_AI_STATE_DIR` move them). While it runs, the server renews the claim. When it ends: an item the agent moved to `review` keeps its status and loses the claim; an item still `in-progress` is released back to `todo` and *held* — `auto` mode does not start it again until a person does (no retry loops on errors or rate limits) — except when the agent asked a question: then it is only released, and it is not ready until somebody answers. For Claude the log's session id is kept in `<id>.last.json`: the next start of the item continues it (see above), and `claude --resume <session>` in the worktree continues it by hand. The `backlog` on the agent's `PATH` must be new enough to read your `backlog.yaml`.

### View (`views/*.yaml`)

```yaml
name: Launch
section: Releases           # optional heading in the app's view list
layout: kanban              # list | kanban | table | graph
filter:                     # a map = AND; also and/or/not
  milestone: launch
  category: {not: [done]}   # {in: [...]}, {not: [...]}, {exists: bool}, {contains: text}
  or:
    - priority: [p0, p1]
    - labels: security
group_by: status
columns: [todo, in-progress, review, done]
sort: [priority, -updated]
```

Views can filter and group by every item field, by custom keys and by the computed fields `ready`, `blocked`, `conflicting`, `conflicts_with`, `claimed`, `claimed_by`, `needs_human`, `category`, `has_children`, `ancestors` (the parent chain) and `epic` (epics among the item and its ancestors, so `epic: X-m4an` is everything under that epic).

## CLI reference

| Command | What it does |
|---|---|
| `init [dir] --prefix MA [--no-register]` | create a backlog and add it to the project registry |
| `new <title> -t -s -p -m --parent -d -l --touches --body --body-file` | create an item |
| `list [-w field=a,b] [-s] [-m] [-l] [-t] [--all]` | list items (without finished ones) |
| `show <id>`, `path <id>` | details, path of the file |
| `set <id> status=review labels+=x touches+=lib/a/ depends_on-=MA-1 milestone=` | edit fields (`=` sets, `+=`/`-=` for lists, empty clears) |
| `ready`, `blocked` | what can be done / what is waiting |
| `next [-w …] --as <agent>` | claim the most urgent ready item |
| `claim / heartbeat / release / done <id> --as <agent>` | work with claims (`--force` overrides the checks) |
| `claims` | who works on what |
| `comment <id> "text" [--as a]`, `ask <id> "question" [--as a]` | add to the item's discussion; `ask` makes it need a person until answered (text `-` reads stdin) |
| `view [name]` | saved views |
| `lint` | consistency: unknown values, broken references, cycles, locks, malformed or overlapping touches, dispatcher worktrees and agent (exit 1 on errors) |
| `instructions` | the guide for agents, in Markdown |
| `projects`, `projects add [dir] [--id] [--name]`, `projects remove <id>` | the registry of backlogs on this machine (`~/.config/kanban-ai/projects.yaml`), see below |

**Project registry:** `backlog init` registers the new backlog by itself (`--no-register` skips it); `backlog projects add` (in a project) registers an existing backlog in `$XDG_CONFIG_HOME/kanban-ai/projects.yaml` (default `~/.config/kanban-ai/projects.yaml`; elsewhere with `BACKLOG_PROJECTS` or `--projects <file>`). The file is plain YAML you can also edit by hand — `projects:` is a list of `{id?, name?, path}`, paths absolute, `~/…` or relative to the file; the id defaults to the project folder's name (the parent of a folder called `backlog`), the first project is the default one, and `pinned: true` is kept for the board's upcoming pinned projects.

Global options are `-C <dir>` and `--json`. The agent comes from `--as` or `BACKLOG_AGENT`. **Exit codes:** 0 ok, 1 error, 2 nothing to do, 3 claim conflict, 4 not found, 64 usage. JSON fields are only ever added, never renamed.

## Architecture

A Dart pub workspace, plus the Flutter app:

```
packages/
  backlog_core/    domain, use cases, file-system adapters
  backlog_cli/     CLI adapter (args), text/JSON output
  backlog_api/     HTTP contract: DTOs, the BacklogApi interface, an HTTP client (pure Dart, runs on the web)
  backlog_server/  shelf: REST over the core, folder watcher + WebSocket, serves the web app
  backlog_app/     Flutter (web, linux): board, detail, editing; outside the workspace, own pubspec.lock
nix/module.nix     NixOS module
tool/playground.sh demo data
```

```
backlog_app ──(BacklogApi)──► HttpBacklogApi ══HTTP/WS══► backlog_server ──► backlog_core ──► files
                    └─────────── backlog_api (shared DTOs) ───────────┘
backlog_cli ─────────────────────────────────────────────────────────────────► backlog_core
```

**The core** is hexagonal and split into modules. Each module has three layers:
- `domain/`: pure code without I/O; ports are interfaces.
- `application/`: use cases.
- `infrastructure/`: file-system adapters.

| Module | domain | application | infrastructure |
|---|---|---|---|
| `workflow` | `Workflow`, statuses and categories, `DispatcherConfig`, `AgentProfile` | – | `backlog.yaml` parser |
| `projects` | `ProjectRegistry`, `ProjectEntry`, port `ProjectRegistryStore` | `ProjectService` | `projects.yaml` (`yaml_edit`, keeps comments) |
| `items` | `Item`, `ItemId`, `Checklist`, ports `ItemRepository`, `IdGenerator` | `ItemService`, `FieldChange` | Markdown codec (`yaml_edit`, keeps formatting), file-system repository |
| `claims` | `Claim` (lease), port `ClaimStore` | `ClaimService` (claim, next, heartbeat, release, drop, done) | lock files |
| `planning` | `BacklogSnapshot`, `PlannedItem`: blocked, conflicting, ready, cycles, children | `PlanningService` | – |
| `dispatch` | `DispatchPlan` (ready items → free worktrees; held items, unavailable worktrees, running agents), port `AgentLauncher` | `Dispatcher` (debounce, wake-up on claim expiry, auto launch, manual start/stop), `LoggingLauncher` | `ProcessAgentLauncher` (detached processes, state files, heartbeat, end of run) |
| `views` | `Filter`, `ViewDefinition`, `ViewEngine` | `ViewService` | YAML views |
| `validation` | `LintIssue` | `Linter` | – |

`Backlog.open()` is the composition root that wires the ports to the file-system adapters. To support several users on a database, you would write other adapters (`ItemRepository`, `ClaimStore`) and leave the domain unchanged. The DDD is light:
- value objects
- an immutable `Item` entity
- the domain service `BacklogSnapshot`, the only place where planning state is computed

There is no event bus or event sourcing: the state lives in files and git keeps the history.

**The server** is a driving adapter. `ApiHandler` parses requests, calls the core services and maps the results through `DtoMapper` to the DTOs of `backlog_api`. `ChangeFeed` watches the folder, debounces bursts of changes and ignores `.git` and temporary files. `BacklogHost` reloads the workflow after `backlog.yaml` changes, the core's `Dispatcher` re-plans on the same change events. The server opens backlogs with an in-memory item cache: each request still lists and `stat`s the item files but parses only those whose modification time, ctime or size changed (recently written files are always re-read, because file times are coarse), so edits by agents, editors or `git` are seen without relying on the watcher; claims are always read fresh (SPEC §8). Each backlog is a `HostedProject` (host, feed, dispatcher, API); `ProjectHub` keeps them in registry order and routes `/api/p/<id>/…`, `RegistryWatcher` applies registry edits live, and `BacklogServer` is the composition root.

**The app** is split by feature (`features/board`, `features/item`, `features/projects`, `features/dispatch`). Each feature has `application/` (`ChangeNotifier` controllers without widgets, and pure logic such as `ColumnArrangement`) and `presentation/`. It depends only on the `BacklogApi` interface, which `AppScope` provides. `ProjectsController` picks the open project from the `ProjectsApi`; each project gets its own session (its `BacklogApi` in `AppScope`, theme, board), thrown away as a whole when another project is opened.

**The REST API** (`/api/…` for the default project, the same under `/api/p/<id>/…` for each project):
- `projects` (global: `[{id, name, path, error}]`)
- `workflow`, `items` (`?all=true`)
- `items/<id>`: GET (with its relations and the items it waits for or holds up through `touches`), and PATCH `{changes: ["status=done"], body}`
- `items/<id>/claim|release|done`: POST `{agent, status, force}`
- `views`: GET, and POST `{name, section?, base?, conditions: [filter expressions]}` (save a filter as a view)
- `views/<id>`: GET (`?group_by=field` regroups it for that request), and PATCH `{section?, columns?}` (only the given keys change; null removes them)
- `lint`, `health` (global)
- the WebSocket `events`

Errors look like `{"error": {"type", "message"}}`, the same as `backlog --json`.

## Development

Tools are pinned with [mise](https://mise.jdx.dev) in `mise.toml`: Flutter 3.32.8 (it bundles Dart 3.8.1, the same version the flake builds with) and jq. Nix is expected at the system level. Alternatively, `nix develop` gives you the same Flutter.

```bash
mise install                    # Flutter + Dart, jq
mise run get                    # dart pub get + flutter pub get in the app
mise run check                  # format check, analysis, all tests — before committing
mise tasks                      # analyze, test, format, build, build-web, playground, serve, install, install-dev
```

| Task | What it does |
|---|---|
| `mise run build` | the web app plus `build/backlog` and `build/backlog-server` |
| `mise run playground` | regenerate `playground/` with demo data |
| `mise run serve` | serve the playground (or `BACKLOG_DIR`) with the built web app |
| `mise run install [ref]` | install `backlog` and `backlog-server` from `main` (or a branch, tag or commit) into `~/.local/bin` with Nix |
| `mise run install-dev` | install `backlog-dev` and `backlog-server-dev` from this worktree, uncommitted changes included |

The same commands without mise:

```bash
dart pub get && (cd packages/backlog_app && flutter pub get)
dart analyze packages/backlog_core packages/backlog_cli packages/backlog_api packages/backlog_server
dart test packages/backlog_core packages/backlog_cli packages/backlog_api packages/backlog_server
(cd packages/backlog_app && flutter analyze && flutter test)
dart format packages            # page width 120
```

The app with hot reload against a running server:

```bash
(cd packages/backlog_app && flutter run -d web-server --web-port 8080)
# → http://localhost:8080/?server=http://localhost:8640&token=…
```

Tests cover every layer:
- domain and codec
- agents racing for items (isolates)
- the CLI end to end
- the client–server contract without sockets, plus one test over real sockets including the WebSocket
- the app's controllers and widgets against `FakeBacklogApi`

That is 95 tests in total. After changing a `pubspec.lock`, just run `nix build`; Nix reads the lock files itself (`autoPubspecLock`).

## Roadmap

- [x] format, core, CLI, tests
- [x] server (REST, watcher, WebSocket) and the web board
- [x] Nix flake and NixOS module
- [ ] use it on a real project
- [ ] app: "Epic › Story" path in context headers, a real dependency graph, table layout, filters in the UI, saving views from the UI
- [ ] server: commit/push from the UI, real users instead of a shared token, several people (database adapters)
- [ ] an MCP server over the core, so that agents do not have to shell out to the CLI
