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
(cd packages/backlog_app && flutter pub get && flutter build web --no-web-resources-cdn --pwa-strategy=none && tool/precompress.sh)
# the server looks for the app in packages/backlog_app/build/web; otherwise --web <dir> or BACKLOG_WEB
```

## Quick start

```bash
cd ~/projects/myapp                    # next to the worktrees: myapp/{monorepo,monorepo-2,…}
backlog init backlog --prefix MA       # creates myapp/backlog/ and registers it for backlog-server
# or with a preset: --preset minimal | agents | agents-review (backlog init --list-presets),
# or --from ../other/backlog to copy another backlog's configuration and views
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
backlog check MA-7f3a 2         # tick checklist item 2 (or by its text); `uncheck` undoes, no number lists them
backlog pr MA-7f3a --description "What, why, how verified"   # push the branch, open the PR (with dispatcher.pr)
backlog done MA-7f3a            # finished: drops the claim, prints what got unblocked
backlog release MA-7f3a         # give it back unfinished
backlog ask MA-7f3a "CSV or JSON?"   # a question for a person; then stop
backlog comment MA-7f3a "Done, see the commit."   # a comment in the item's discussion
backlog lint                    # before ending the session
```

*Most urgent* means: the earliest milestone in the order of `backlog.yaml` (no milestone, `later` and unknown ones last), then priority, then age, then id.

**Checklist:** `backlog check <id> <n|text>` / `backlog uncheck …` tick the `- [ ]` lines of an item's body by number or text and change nothing else in the file, so an agent never needs to edit an item file outside its worktree (the default prompts say so); `backlog check <id>` lists the numbered checklist.

**Claims:** `claim` and `next` atomically create `.locks/<id>.lock` (O_EXCL), so when several agents race for an item exactly one wins. This is verified by a test with 12 isolates and by hand with 10 parallel processes. Without a `heartbeat` the lock expires after its lease and another agent may take the item over. The item file mirrors `status: in-progress` and `assignee`, so humans see who works on what. Locks are machine-local state (gitignored) and work on a local disk, not on network file systems.

**Ready** means the status is `pickable` (`todo` by default), all `depends_on` items are done, there are no open children, nobody holds a claim, the item's `touches` do not overlap an item in progress, and no question in it waits for a person.

**Discussion:** `backlog comment <id> "text"` and `backlog ask <id> "question"` append to a `## Discussion` section at the end of the item's body (author = `--as`, `BACKLOG_AGENT` or `$USER`; text `-` reads stdin). A question that nobody else has answered yet makes the item **need a person** (`needs_human`): it is not ready, so `next` and the dispatcher skip it, until someone answers with a comment. `backlog comment --note` adds only a note: it answers no question and does not wake the item's agent (see *Talking to the agent*). `backlog review <id> --ok "…"` / `--changes "…"` records the verdict of a review (by an AI review agent or a person) the same way, naming the reviewed commit of the item's branch. `backlog list -w needs_human=true` lists them; `show` says `NEEDS A PERSON`. When a discussion changes what the item asks for, the description or acceptance criteria above `## Discussion` are updated and the comments stay as the history.

**A whole epic on one branch:** `backlog epic <id>` checks whether one agent can implement an epic (or any item with children) in one go: its items at any depth in the order they can be done (dependencies and children first, then by urgency), each *done*, *handed over* (e.g. `review`), *in progress* or *to do*, and what it waits for. Items handed over count as finished for the items after them, since their work is already on the epic's branch. The verdict is **ok**, **warning** (a dependency outside the epic that is planned but not done, a question waiting for a person, overlapping work outside the epic, an item someone else holds — the agent will stop there and ask) or **cannot start** (a dependency outside the epic that is missing or not even planned, a dependency cycle, nothing left to do, the epic done or claimed by someone else). `backlog epic <id> --next` claims the next item for the agent — the one it has in progress, else the first that can start — and puts it on the epic's branch (`branch` field: the epic's, else `agent/<epic id>`); exit 2 when nothing can start, with the reason.

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
| `--web` | `BACKLOG_WEB`, else `packages/backlog_app/build/web` | the built web app (served with ETags and `no-cache`, so browsers pick up a new build at once; Brotli or gzip copies made by the build are sent to browsers that accept them) |
| `-q` | | do not log requests |
| `--config` | `BACKLOG_SERVER_CONFIG`, else `~/.config/kanban-ai/server.yaml` if it exists | settings file (below) |

**Settings file:** instead of long command lines, put the settings into `~/.config/kanban-ai/server.yaml` (edit it in `backlog config` › Global › Server, which can also generate a token); options and environment variables still win:

```yaml
host: [127.0.0.1, 10.77.1.2]   # or "127.0.0.1, 10.77.1.2"
port: 8642
allow: [127.0.0.1, 10.77.0.0/16]
token: 3Xk…                    # clients send it; the printed URLs include it
web: ~/kanban-ai/web           # absolute, ~/… or relative to this file
projects: ~/.config/kanban-ai/projects.yaml
quiet: true
```

API responses (1 kB and more) are gzip-compressed for clients that accept it.

URL parameters of the app: `?token=…`, `&as=name` (who claims items from the UI) and `&server=http://…` (another API server, handy with `flutter run -d web-server`).

The open project is in the URL after `#`: `http://host:8640/?token=…#/p/kanban-ai`. Such a link can be shared or reloaded; without one the app opens the project you used last in this browser, else the server's first project. The page title is the project's name, with *(N)* in front while N things wait for you in any project (see *Dashboard*). The switcher on top of the navigation lists the pinned projects (all of them while none is pinned) and *All projects…*, a searchable list where the pin button pins or unpins a project for everybody (the server writes it into `projects.yaml`). Switching projects starts the board afresh (no filters, open items or live updates carry over), except that each project opens on the view you last chose in it (remembered per browser). With a server that does not know projects yet the app shows its one backlog as before.

**Features:**
- **Layout:** from 1200 px the views are in a left panel and the open item in a panel on the right; on tablets the views are tabs under the header and the item is a bottom sheet; on phones a bottom bar holds the pinned views. On very wide screens (from 2000 px, e.g. 27" 4K) text is 15 % larger.
- **Projects:** the project's name tops the left panel (and the drawer on tablets and phones); with several projects on the server it is a menu for switching between them. A project the server cannot open is listed with the reason and cannot be chosen.
- **Left panel:** saved views with their item counts and a button for new items (the dialog has an optional *Parent*, searched by id or title; *Add child* in an item's detail opens it under that item with the type one level down: epic → story → task → subtask, as far as your workflow has those types; on phones it is a full page that leaves room for the keyboard). Views with a `section` are listed under foldable section headings. The ⋮ menu of a view moves it to an existing or new section, and the server writes `section:` into its YAML. Below 1200 px the views are tabs under the header (and in a drawer behind ☰); on phones a bottom bar shows the views pinned with the ⋮ menu ("Pin to bottom bar") plus *More*.
- **Cards:** id and priority on top, the title, and one meta line that tells the state: *? Waits for you* (an agent asked a question; warning-coloured border), *Ready*, *Blocked by …*, *Waits for …* (touches overlap work in progress), the claim holder with the time left, an expired claim (faint, dashed border) or else the labels; next to the PR link the **AI review** state (*AI review…*, *AI review ✓*, *AI review: 3 findings*, *AI review outdated*); a thin bar shows progress of the checklist or children.
- **Dashboard:** *Dashboard* on top of the left panel (with a badge: how many things wait for you, in every project) opens one page across all projects of the server, live, with a project filter. *Needs you*: agents' questions with an answer field right there, items in `review` with their AI review state, PR link and the status's actions (*Merge*, …), *Problems* (items whose last run went wrong: a failed exit, denied permissions, a pull request that could not be opened), held items with the reason, and clean-up (expired claims, unavailable worktrees, lint). *Running*: every agent or action with its worktree and start time and *Stop*, and the dispatcher's queue (capacity, next starts with *Start* in `manual` mode, queued starts with *Cancel*, waiting items and why). *Overview*: milestone progress bars and the urgent (two most urgent priorities) work of the current milestone. A row opens its item as a page with that project. On phones the sections stack, *Needs you* first.
- **Ids:** clicking an item id (on a card or in the detail) copies it to the clipboard.
- **Discussion:** under the description the detail shows the item's comments (questions of agents highlighted while open, *Waits for you* under the title) and a reply field. *Send* adds a comment; when the item's last agent session can be continued, the dispatcher resumes the agent with your reply by itself (in `manual` mode too). **Note only** (shown with such a session or an open question) saves a note that wakes nobody and answers nothing. Editing the description leaves the discussion as it is.
- **Actions:** the actions of an item's status are buttons in their own row under the detail's header (with many of them, the rest behind *More…*) and a small ⋯ menu on its card (icons: agent, command, built-in); the detail's agent box shows a running action with its live log and *Stop*, and hooks waiting to run (*Queued: the action "AI review"*). The result lands as a note in the discussion.
- **Offline:** the board loads nothing from other hosts — CanvasKit, Roboto and a symbol font (arrows, ticks, shapes, box lines) come from the server, compressed. Only emoji and scripts outside these fonts (CJK, …) are fetched from Google Fonts when they appear.
- **Pull requests:** an item's `pr` link shows as a "PR #42" tag that opens it in a new tab; it can be set in the detail or by an agent (`backlog set <id> pr=<url>`).
- **Kanban:** the board scrolls as one page, columns grow with their cards and share the width. On a phone you see one column at a time and swipe (or tap the column switcher on top) to the others; a long press on a card moves it to another column. Dragging a card to another column sets the field the view is grouped by (status, priority, …). A parent with nested items in a column (an epic, a story) has a fold toggle that hides them and shows how many are hidden. Within a column, children are indented under their parent. When the parent (an epic, say) sits in another column, it appears as a header above its children (its type icon and title in bold over a thin rule), so you can see which epic a story in progress belongs to.
- **Filter bar:** search (id, title, branch) and a Filters popover (long sections show the six most used values, *Show all* and a search box) for labels, epic (everything under the chosen epic, at any depth), type, priority, milestone, people (assignee or claim holder) and AI review (running, changes, outdated, OK), plus the segments *Needs you* (an agent's question waits for an answer), *Ready* (pickable status, dependencies done, no open children, nobody holds it), *Blocked* (waits for an unfinished dependency), *Waiting* (its touches overlap an item in progress) and *Claimed* (someone holds it, i.e. it is being worked on). Values within one section are alternatives; everything else must match. The filter works on any view and is kept when switching views; status is left out because views show it already. On phones the bar is hidden behind a search button in the header (a dot on it means a filter is active), so the board keeps the screen. **Save as view** stores the current view plus the filter as a new view (name and optional section; the new file in `views/` keeps the layout, grouping, columns and sorting of the current view and ANDs its filter with yours).
- **Detail:** opens in a right-hand panel on wide windows, in a bottom sheet over the board on medium ones and full-screen on narrow ones (Esc closes it). You can edit all fields, labels, touches (paths or globs, as chips), relations (parent, dependencies, related), the Markdown description, and claim, release or finish the item: the title right where it is shown, status and priority from their dropdowns, the rest from the list of fields below them. Checklist items in the description are checkboxes: ticking one rewrites its `- [ ]` line in the file. The header shows the parent chain as a breadcrumb (*Launch hardening › X-2c91 Restore drill*) and the item's place among its siblings (*Story 2 of 5*, with ‹ › to step to the neighbours). Children are listed with their progress (*Tasks 1 of 3 done*); ▸ expands a child in place to the start of its description and its own children, *Open X →* shows it. A line names what the item is blocked by or waits for (overlapping touches), or which open items wait for it. Parent, depends on, blocks and related are folded rows with a count; empty kinds are left out and new links are added from the *Link:* row. Whatever you open from the detail — an ancestor, a sibling, a child, a linked item — replaces it in the same panel, and ← goes back the way you came. An epic's *Scope board* button narrows the board to everything under it. Esc closes the panel.
- **The `graph` layout** (default view "Dependencies") shows each item with an expandable tree of its dependencies, including their titles and statuses. Clicking a dependency opens its detail.
- **People:** the left panel lists the agents that hold claims right now with their item counts; a click shows what that agent works on.
- **Agents (dispatcher):** with a `dispatcher` section the left panel shows *Agents · mode · running/max*: each worktree with the item its agent works on, *free*, *new* (to be created for a proposed start) or *unavailable* (the reason in the tooltip, e.g. uncommitted changes), with `repo` also how many worktrees exist of `max_worktrees`, the proposed next starts (▶ starts one in `manual` mode; ↻ continues the item's last session, *(new)* creates the worktree first) and held items. A ready item's detail has **Start agent** (in either mode) — or **Continue agent** and **Start fresh** when its last agent session can be continued (in that session's worktree); while an agent works on an item, its detail shows the agent, worktree, start time and branch, **Stop** (terminates it; the item goes back to the queue, held) and its **live log**: what Claude says, each tool call on one line (`▸ Bash git status`, `▸ Edit lib/a.dart`), failures, and at the end turns, time, cost and the session id; other agents' output as it is. It stays at the newest line and pauses while you scroll up. After the run the box keeps the last run's log and how it ended (exit code, outcome, `claude --resume <session>`). The box tells the state at a glance: the agent runs (since when, the last line of its log), it is done and fine (green), the last run ended with problems that need you (red, with the list: a failed exit, an error ending, denied tool calls, a pull request that could not be opened; an action that went well afterwards, such as the AI review, does not hide them — only the agent's next run does; a finished item shows them in grey, as history), held or waiting (amber, with why), an item the agent of its epic works on (that agent, its live log and a link to the epic; the Dashboard's *Running* row says `on <item>`), and a message you wrote while an action runs that waits for it to end (*A message waits: the agent continues after the action "AI review" ends*, also under the discussion); after a run it also shows the agent's last message (Claude's `result`). A card whose item has such problems or is held shows a small red or amber sign (the tooltip says why). The plan updates live. **Queue of starts:** a start you ask for that cannot happen now — *Start agent*, *Implement epic* or an action while no worktree is free, `max_agents` is reached, something already runs for the item or its branch is busy elsewhere — is queued instead of refused (also from `backlog action`), kept across server restarts and started by itself as soon as it can, in queue order (after agents woken by replies, before new work); the item says *Queued: Start agent waits for <reason> · position N* with *Cancel*, the notice *Queued: …*. What can never start (a done item, an epic with open children without Implement epic) is still refused with the reason. An item with children has **Implement epic**: a dialog shows whether one agent can do all of it on one branch (the verdict with its problems or warnings and the items in work order, what each waits for) and starts it (*Start anyway* with warnings, no start when it cannot); while it is implemented, the epic's detail shows how far its items are.
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

**The discussion** is the last section, `## Discussion`, written by `backlog comment` / `backlog ask` (and the board): one `### <author> · <date time> UTC` heading per comment, ` · question` for a question that waits for a person, ` · note` for a note, ` · review ok` / ` · review changes @<commit>` for a review (its numbered list items are its findings). It is plain Markdown, so it can be read and edited by hand (seconds and `UTC` may be left out); a comment ends at the next comment heading, the section at the next `#`/`##` heading.

Derived properties are computed, never stored: `blocked`, `conflicting` (waits for overlapping work in progress), `needs_human` (an unanswered question), `review` (the latest review: `ok`, `changes` — with `review_findings` —, `stale` when the item's branch has newer commits, or `none`), `ready`, and the progress of the checklist and of the children.

### Workflow (`backlog.yaml`)

`backlog init` writes a commented file with:
- statuses `backlog`, `todo`, `in-progress`, `review`, `done` and `cancelled`
- priorities `p0`–`p3`
- types, milestones, defaults and the claim lease
- commented examples of `appearance` and `dispatcher` (with actions)

**Presets:** `backlog init --preset <name>` starts from another kanban: `minimal` (a personal to-do list: todo / in-progress / done, no milestones, no dispatcher), `default` (the file above), `agents` (set up like kanban-ai itself: a review status, versions as milestones plus `later`, a manual dispatcher that creates its own worktrees next to the repository — `--repo`, default the parent folder — and a guide for the repository's `CLAUDE.md` / `AGENTS.md`, printed or appended with `--agents-file CLAUDE.md`) and `agents-review` (plus an AI review on entering review and a local *Merge* button). Own presets are folders in `~/.config/kanban-ai/presets/<name>/` (`backlog.yaml`, optional `views/`, `AGENTS.md`, `preset.yaml` with a description) with the placeholders `${prefix}`, `${project}`, `${repo}`, `${repo_name}`; `--preset ./folder` takes one from anywhere, `--from <backlog>` copies the configuration and views of an existing backlog without its items. `backlog init --list-presets` lists them.

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
  mode: manual          # manual: a person presses Start in the board (replies still wake agents) | auto: starts by itself
  max_agents: 2         # default: one per worktree
  worktrees:            # path relative to the backlog folder; a bare name means ../<name>
    - name: monorepo-2
      path: ../monorepo-2
    - monorepo-3
  repo: ../monorepo     # optional: create worktrees from this clone when none is free
  max_worktrees: 4      # with repo: listed + created
  base: main            # new branches agent/<id> start here
  agent: claude         # a profile; claude is the default
  allow: ["Bash(dotnet *)"]   # optional: Claude Code rules added to the claude whitelist
  deny: [WebFetch]      # optional: added to its deny list (pushing stays denied)
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
  actions:              # optional: buttons on items and hooks on statuses (see Actions below)
    - name: Fix PR comments
      statuses: [review]                 # where the button shows (default: every status)
      prompt: "Go through the unresolved comments of PR {pr}, fix them and answer them."
    - name: AI review
      review: true                       # the built-in review task (see AI review below)
      on_enter: review                   # runs by itself when an item enters review
    - name: Tests
      statuses: [review]
      run: [sh, -c, "mise run check"]    # a command (a list); run: <name> is a built-in action
  pr:                   # optional: agents push their branch and open a pull request
    remote: origin      # default
    create: 'tea pulls create --head {branch} --base {base} --title "{id}: {title}" --description-file -'
    # create: 'gh pr create --head {branch} --base {base} --title "{id}: {title}" --body-file -'
    # find: 'gh pr list --head {branch} --json url --jq ".[0].url"'   # optional: a PR opened elsewhere
    # url_pattern: 'https://\S+/pulls/\d+'   # optional; default: the first URL in the output
    # review: 'tea comment {pr_number}'   # optional: backlog review also posts the review to the PR
    # review: 'gh pr review {pr} --comment --body-file -'
    # merge: tea pulls merge --style rebase {pr_number}   # how `run: merge` merges ({pr} = URL)
    # merge: gh pr merge --rebase {pr}
    # state: gh pr view {pr} --json state --jq .state      # merged/closed/open: notices PRs merged elsewhere
  merge:                # optional: how the built-in action merge merges (see Merging below)
    strategy: local     # pr (default with pr) | local (default without) | command
    check: mise run check   # local: after the rebase onto base
    push: false         # local: push the merged base
    cleanup: true       # remove branch, created worktree and session afterwards (default)
```

**Agent profiles.** A profile is a command template, extra environment (`env`) and the format of its output. Built in:

| Profile | Command | Status |
|---|---|---|
| `claude` (default) | `claude -p {prompt} --output-format stream-json --verbose --permission-mode acceptEdits --permission-prompts none --allowedTools "Bash(backlog *) Bash(git *) Bash(mise *) Bash(dart *) Bash(flutter *) Bash(./*) Bash(ls *) Bash(cat *) Bash(head *) Bash(tail *) Bash(wc *) Bash(find *) Bash(grep *) Bash(rg *) Bash(jq *) Bash(diff *) Bash(sort *) Read Edit Write Grep Glob TodoWrite WebFetch WebSearch" --disallowedTools "Bash(git push *) Bash(git -*) Bash(git send-pack *) Bash(git config *alias*)"` | verified with Claude Code 2.1 |
| `codex` | `codex exec --full-auto --json {prompt}` | unverified preset |
| `gemini` | `gemini --approval-mode auto_edit -p {prompt}` | unverified preset |
| `aider` | `aider --yes-always --message {prompt}` | unverified preset |

The `claude` profile runs Claude Code headless on your subscription login: no API key, never `--bare` (it ignores the login) and never `--dangerously-skip-permissions` — edits are accepted, a whitelist of tools is allowed (`backlog`, `git`, `mise`, `dart`, `flutter`, the project's own scripts run as `./…`, the read-only commands `ls`, `cat`, `head`, `tail`, `wc`, `find`, `grep`, `rg`, `jq`, `diff`, `sort`, web search and fetch, the file tools), everything else is refused and pushing is forbidden: `git push`, but also git with global options in front (`git -C . push` slips past a plain `Bash(git push *)` rule, so `git -C`, `git -c`, `git --no-pager` … are refused altogether), `git send-pack` and git aliases. This guards against mistakes, not against an agent set on pushing (it may run the project's own scripts); protect your base branch on the server too. It is also the one profile that can **resume**: its `resume` arguments (`--resume {session}`) continue an earlier session. For other tools (tests of another language, …) list Claude Code permission rules in `dispatcher.allow` (e.g. `["Bash(dotnet *)", "Bash(npm *)"]`): they are added to the `--allowedTools` of the `claude` profile — and of own profiles whose command has an `--allowedTools` list — without copying the whole command; `dispatcher.deny` adds rules to `--disallowedTools` the same way (the push ban always stays). `lint` warns (`dispatcher-allow`) when the agent, or the agent of a prompt action, has no `--allowedTools` list, so the rules do not apply to it. The unverified presets follow the CLIs' documentation and have not been run here; `lint` reminds you of that.

**The prompt** (`dispatcher.prompt`) is shared by all profiles and fills `{prompt}`. By default it tells the agent its name and item, to run `backlog instructions` and `backlog show {id}` first, to commit on the branch prepared for it in small commits with the item id, to finish with `backlog set {id} status=review`, never to push (with `pr`: to open the pull request with `backlog pr`, see below), when something is unclear to ask with `backlog ask` and stop, and to update the description when a discussion changes the assignment.

**Pull requests** (`dispatcher.pr`). Without it agents never push: the work stays on the item's branch in the worktree and a person merges it. With it, the default prompt asks the agent to finish by writing a pull request description (what and why, how it was verified, the item) to `.kanban-ai/pr-<id>.md` and running `backlog pr <id> --description-file .kanban-ai/pr-<id>.md`, then `backlog set <id> status=review`. Agents keep every command on one line (their tool whitelist denies commands that span lines): long texts go into files in `.kanban-ai/` — which kanban-ai makes git ignore (`info/exclude`) and never counts as uncommitted changes — and `backlog comment`, `ask` and `review` take them with `--file`. `backlog pr` pushes the item's branch (its `branch` field, else the checked-out branch) to `remote` — under its own name, never forced, and never the `base` branch — then runs `create` in the worktree with the description on its standard input (and in `{description}`), takes the pull request's URL from the output (`url_pattern`, default the first URL) and writes it into the item's `pr` field, which the board shows as a link on the card and in the detail. It is idempotent: when `pr` is set (or `find` prints the URL of a pull request opened elsewhere) it only pushes, so new commits after a review reach the open pull request. After a rebase (resolving conflicts with the base) `backlog pr <id> --force` replaces the remote branch with `--force-with-lease` — only when it is still what was last pushed from there, and never the base. Placeholders: `{id}`, `{title}`, `{branch}`, `{base}`, `{remote}`, `{description}`; no shell runs the commands. The built-in `claude` profile still cannot run `git push` itself — `backlog pr` is the agent's only way out of the worktree; protecting the base branch on the server (Gitea, GitHub) is still recommended. `lint` warns when the `create` or `find` program is not on the `PATH`.

**Continuing a session.** Starting the same item again — after *Stop*, after an agent ended without finishing, or by hand later — continues its last agent's session instead of starting a new one, when the profile can resume (`resume:`; only `claude`, whose session id kanban-ai reads from the `claude-stream-json` output) and that session's worktree is free: the agent sessions live per folder, so it runs in the same worktree again (other items leave that worktree to it when they can, also while its agent waits for an answer). It then gets `dispatcher.resume_prompt` (default: you are continuing item {id}, `{news}` — how the last run ended —, look at the item again and go on under the same rules). Otherwise, or with *Start fresh* (`POST /api/dispatch/start {"item", "fresh": true}`), a new session starts.

**Talking to the agent of an item.** When someone other than the agent comments on an unfinished item whose last session can be continued — an answer to the agent's `backlog ask`, or a question like "why did you do it this way?" on an item in review — the dispatcher resumes that session in its worktree with the new comments in `{news}`: right away, in `manual` mode too (manual only means the dispatcher takes no new work by itself; a reply is an explicit instruction), before other work and even for held items. The default resume prompt tells the agent to answer with `backlog comment` and stop when it was only asked something, or to reply and continue the work when it got an answer or a change request, and to bring the description up to date when the discussion changed the assignment. If the session's worktree is busy, the reply waits for it. When there is no session to continue (the item was worked on elsewhere, or its session's worktree is gone), a reply — also the dispatcher's comment about a failed merge — starts a **new session** of the agent instead, in the worktree with the item's branch if one is free, with the new comments in `{news}`; the item keeps its status. When such an agent cannot start yet, the item's agent box and the *Agents* panel say why (*Waiting for an agent: no free worktree*). A **note** (`backlog comment --note`, *Note only* on the board, `note: true` in the API) is the exception: it does not wake the agent and does not answer its question; the agent sees notes as context in `{news}` the next time it continues.

Commands are split into arguments like in a shell, but no shell runs them (use `[sh, -c, "…"]` if you need one). Placeholders in the prompt, commands and `env`: `{id}`, `{title}`, `{worktree}`, `{path}` (absolute path of the worktree), `{backlog}`, `{branch}`; commands and `env` also `{prompt}`. The agent always gets `BACKLOG_AGENT=<worktree>` and `BACKLOG_DIR=<backlog folder>`; agents and action commands also `GIT_EDITOR=true` and `GIT_SEQUENCE_EDITOR=true`, so git never waits for an editor (a profile's `env` may replace them). The older `command: …` (instead of `agent`) still works as a plain profile. Mistakes in the section are configuration errors; `lint` warns about worktree paths that do not exist, a `repo` that is not a folder, an agent command that is not on the `PATH` and unverified presets. A running `backlog-server` re-plans after every change and whenever a claim expires: ready items in the order of `backlog next` go to free worktrees, at most `max_agents` at once, and it logs the plan. In `auto` mode it starts each new assignment by itself; in `manual` mode it only proposes new work and a person presses *Start agent* on the board (or `POST /api/dispatch/start`) — on any ready item, not only the proposed ones, while fewer than `max_agents` run and a worktree is free or can be created; proposals reserve nothing — replies to an agent still resume it by itself.

**Implementing an epic** (a person's start, never automatic): one agent, one branch, one session and one pull request for a whole epic. The epic is checked first (`backlog epic`, see above; *cannot start* refuses), then the agent claims the epic, works on its branch (`agent/<epic id>`) and takes the items with `backlog epic <id> --next` one by one — each implemented in commits with its id and handed over to `review` — picking up items unblocked meanwhile. When the rest waits for something outside the epic it asks on the epic (`backlog ask`) and stops; the answer resumes it in the same session. At the end it opens one pull request for the epic (with `dispatcher.pr`) and sets the epic to `review`, where an AI review hook reviews the whole branch. Meanwhile the items under the epic are never handed to other agents and their own `on_enter` actions are dropped; when the agent ends, its claims on them are given back (unfinished ones to `todo`; handed-over ones keep the epic's branch as theirs). A comment on an item with open children that is not implemented this way wakes no agent; the board says *start Implement epic to take the reply up*.

**Worktrees on demand.** With `repo` (the primary clone) the dispatcher does not need a fixed list: when no worktree is free it adds one next to the clone with `git worktree add` from `base`, named `{repo}-{n}` (change it with `worktree_name`; the first unused number from 2 on), up to `max_worktrees` worktrees in all, listed ones included. It remembers which worktrees it created (`~/.local/state/kanban-ai/worktrees/<project>/`) and reuses them; folders it did not create are left alone. The plan says when a start will create a worktree (*→ monorepo-3 (new)*). `cleanup_after_days: 14` removes created worktrees idle that long, but only when that loses nothing: no uncommitted changes and nothing that is not merged into `base` (`git worktree remove`, never forced; branches stay). Off by default. `setup: [[mise, trust], [mise, run, get]]` prepares each new worktree before its first agent starts (trusting `mise.toml`, which agents may not do, and fetching dependencies); when a command fails the worktree is removed again and the start fails with the command and its log. A continued session always runs in its own worktree, never in a new one: new work takes free worktrees first, then new ones, and leaves the worktree of a session that is about to continue — a ready item's, or that of an agent waiting for the answer to its question — alone when it can. So cleanup also keeps every worktree that holds the last session of an unfinished item, however idle, and does not reuse its name. If such a worktree is gone anyway (removed by hand), its session cannot be continued: the next start of the item is a new session, and a reply on an item that is not ready (e.g. in review) waits until a person starts it again; a *listed* worktree that is missing is only unavailable, and its sessions wait for it.

**Actions** are the generic "button with a prompt or a command". Each entry of `dispatcher.actions` has a `name` and exactly one of `prompt` (an agent; `agent:` picks a profile, `fresh: true` a new session), `review: true` (an AI review, below) or `run` (a command as a list, or the name of a built-in action: `noop`, or `merge` — see *Merging* below). `statuses` says where it is a button (default every status; with `on_enter` only that status; `[]` none), `on_enter: <status>` makes it a hook that runs by itself whenever an item enters that status — once per transition, in `manual` mode too, and a restarted server neither repeats it nor forgets one it missed (it remembers the statuses it saw in `~/.local/state/kanban-ai/actions/<project>/state.json`). A hook waits until nothing else runs for the item (typically the agent that just set `review`) and is dropped when the item leaves the status first. Placeholders: prompts have the prompt's ones plus `{pr}`, `{status}`, `{base}`, `{action}`, `{news}`; commands `{id} {title} {branch} {pr} {status} {worktree} {path} {backlog} {base} {action}`.
- A **prompt action** runs an agent like the dispatcher does, but it **does not take the item over**: the claim is taken under the worktree without changing the status or assignee (an action in `review` leaves the item in `review`), nothing is ever held, and the claim is dropped at the end. It continues the item's session in its worktree (`{news}` tells what happened since), unless `fresh: true`; a fresh run prefers the worktree that has the item's branch checked out and stays a side session, so the item keeps its own one for replies. With `pr` set, the agent pushes its fixes with `backlog pr <id>` into the item's pull request.
- A **command** runs detached in the worktree that has the item's branch checked out (else in the primary clone `repo`), like an agent with a log; the worktree is busy meanwhile. Nothing is claimed.
- A command ends with a **note** in the item's discussion (it wakes no agent): exit code, duration and the last 20 lines of output; a prompt action's agent leaves a note only when it fails, and comments only when the action asks it to. Agents keep the discussion for questions, answers and problems: no "thanks, on it", no progress reports, no summaries of work that went well — but one comment when something failed or they could not finish (a push or pull request failed, checks do not pass, a permission was denied), saying what is needed.
- Run one from the board (buttons in the detail, the ⋯ menu on a card), with `POST /api/items/<id>/actions/<name>` or `backlog action <id> "<name>"` (the CLI only leaves a request in `.locks/actions/` that the running server picks up; without a name it lists the item's actions). Only one thing runs for an item at a time.

**AI review.** An action with `review: true` is an AI review: an agent in a new session (always `fresh`) gets a built-in task — review the changes of the item's branch against `base` (`git diff {base}...{branch}`, the pull request if there is one), read the item and its discussion and the project's rules (CLAUDE.md, AGENTS.md, …), check correctness, tests, documentation, security and scope, change nothing and push nothing — and finishes with `backlog review <id> --ok "…"` or `--changes "summary + numbered findings"`. A `prompt` on such an action is added to the built-in task (`prompt: "Also check the migrations."`); `agent:` picks the profile as usual. With `on_enter: review` every item handed over for review gets one automatically — unless the latest review already saw the current head of its branch (it came back without new commits, e.g. after a failed merge); the button always runs one:

```yaml
  actions:
    - name: AI review
      review: true
      on_enter: review
```

The verdict is a review comment in the discussion (`### reviewer · … · review changes @1a2b3c4d5e6f`): it is for the person and for the item's agent — a later resume of the agent shows it in `{news}` — but, like a note, it does not answer a question and does not wake the agent by itself. With `pr.review` configured (`tea comment {pr_number}`, `gh pr review {pr} --comment --body-file -`; the review comes on stdin and in `{body}`) `backlog review` also posts it to the item's pull request as a comment — never as an approval; when that fails the review stays in the discussion and a note says why. The item's `review` state follows the latest one: `ok`, `changes` (with the number of findings), `stale` once the item's branch has newer commits than the reviewed one, `none`.

**Review ↔ fix loop** (optional, off by default): with `auto_fix: 2` on the review action a review that asks for changes wakes the item's own agent in its session with a prompt to fix the findings (commit, `backlog pr`, set the status again; a comment only for findings it leaves unfixed); once it has pushed new commits the review runs again, at most two rounds, then a note says a person decides. A fix without new commits, an `ok` review or one without a verdict end the loop, and so does a merge (the item is done). It runs in `manual` mode too, like hooks. After a failed merge (below) the item is back in `review`, so the AI review is queued again; the agent woken by the failure comment fixes the branch first and the review then looks at the fixed one.

```yaml
    - name: AI review
      review: true
      on_enter: review
      auto_fix: 2
```

**Merging** (`run: merge`). A built-in action that merges an item's branch the way `dispatcher.merge` says — typically a hook on a `deploy` status (category `active`, after `review`), so that dragging a card to *deploy* merges it, and also a *Merge* button in review:

```yaml
statuses: [..., {id: review, category: active}, {id: deploy, category: active}, {id: done, category: done}, ...]
dispatcher:
  actions:
    - name: Merge
      on_enter: deploy
      statuses: [review]
      run: merge
  merge: {strategy: local, check: mise run check, push: true}   # or strategy: pr with pr.merge
```

- `local`: in the item's worktree (or a temporary one next to the primary clone) the branch is rebased onto `base` when needed, `check` runs, `push` pushes the new base (never forced), and `base` is fast-forwarded in the primary clone — which must have no uncommitted changes to tracked files.
- `pr`: `dispatcher.pr.merge` merges the pull request: `tea pulls merge --style rebase {pr_number}` (Gitea) or `gh pr merge --rebase {pr}` (GitHub); `{pr}` is the item's `pr` URL, `{pr_number}` the number at its end.
- `command`: your own `merge.command` (exit code 0 = merged).

On success the item is **done** — an epic implemented on one branch together with its items on that branch; an epic with unfinished items left (todo items without work on the branch) stays open instead, goes back to review without its `pr` (the next *Implement epic* starts a new branch from `base`) and the note says what was deployed and what remains —, and (`cleanup: true`, the default) the worktree the dispatcher created for it is removed (a listed worktree only goes back to `base`, detached; anything with uncommitted changes stays), its branch is deleted when nothing is lost (merged into `base`, or exactly what was pushed to the pull request) and its agent session is dropped; the note says what happened. On failure (a rebase conflict, a failing check, a refused merge or push) nothing is left half done (the rebase is aborted, the branch keeps its commits), the item goes **back to review** (the status it came from) and gets a **comment** with the reason, the end of the output and numbered steps to fix it, each allowed by the agent's whitelist (`git fetch`, `git rebase <base>`, resolve, `git add`, `git rebase --continue`, the check, `backlog pr <id> --force`, leave the status; then move it to deploy again). Being a comment, it resumes the item's agent session like a reply from a person — at once, in `manual` mode too — so "fix the conflicts" needs no extra configuration. Problems for a person (uncommitted changes in the primary clone, no pull request) are only a note. A single item whose work is on its epic's branch together with other unfinished items is not merged on its own: it goes back with a note to deploy the epic (its detail offers *Deploy epic*, which opens the epic); the only item on that branch is merged as usual. The run shows in the plan like any action.

**Merged elsewhere.** With `dispatcher.pr.state` the server notices pull requests merged on the forge itself: every `state_every` minutes (default 2) it asks for the state of the pull request of each item in an active status with a `pr` (and nothing running for it). Merged → the item is done (an epic with items left stays open, as above) and cleaned up as above, with a note; closed without merge → one note, the item stays. The command prints `merged`/`closed`/`open` or JSON with `state`/`merged`: `gh pr view {pr} --json state --jq .state` for GitHub, `tea api repos/{{owner}}/{{repo}}/pulls/{pr_number}` for Gitea.

**How an agent runs.** The server checks that the worktree is a clean git worktree (uncommitted changes or untracked files make it unavailable until cleaned up), claims the item under the worktree's name (if someone was faster, nothing starts), switches the worktree to the item's branch (its `branch` field, else `agent/<id>` created from `base` and written into the item; when another worktree of the dispatcher has that branch checked out, e.g. after a `fresh` review there, and is free and clean, it is detached first — otherwise the item is held with a note saying where the branch is stuck, until it is free) and starts the agent there as a detached process: it keeps running when the server restarts, and a restarted server finds it again. Its output goes to `~/.local/state/kanban-ai/logs/<project>/<id>-<time>.log`, its pid and details to `~/.local/state/kanban-ai/agents/<project>/<id>.json` (`$XDG_STATE_HOME` or `$KANBAN_AI_STATE_DIR` move them). While it runs, the server renews the claim. When it ends: an item the agent moved to `review` keeps its status and loses the claim — and with `dispatcher.pr`, when it has commits but no `pr` (the agent forgot `backlog pr`, or it failed), the server pushes the branch and opens the pull request itself, with the agent's last message as the description, and leaves a note in the discussion (or, when that fails too, a note saying why; the item stays in review); an item still `in-progress` is released back to `todo` and *held* — `auto` mode does not start it again until a person does (no retry loops on errors or rate limits) — except when the agent asked a question: then it is only released, and it is not ready until somebody answers. For Claude the log's session id is kept in `<id>.last.json`: the next start of the item continues it (see above), and `claude --resume <session>` in the worktree continues it by hand. The `backlog` on the agent's `PATH` must be new enough to read your `backlog.yaml`.

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
| `describe <id> --file f [--section "Acceptance criteria"]` | replace the description above `## Discussion` (or only one `##` section) without editing the file; the discussion stays — how agents update what their item asks for |
| `ready`, `blocked` | what can be done / what is waiting |
| `next [-w …] --as <agent>` | claim the most urgent ready item |
| `epic <id> [--next --as <agent>]` | implementing an epic on one branch: whether it can start, what is done, what comes next; `--next` claims its next item onto the epic's branch (exit 2 = nothing can start) |
| `claim / heartbeat / release / done <id> --as <agent>` | work with claims (`--force` overrides the checks) |
| `claims` | who works on what |
| `comment <id> "text" [--as a] [--note]`, `ask <id> "question" [--as a]` | add to the item's discussion; `ask` makes it need a person until answered, `--note` neither answers nor wakes the agent (text `-` reads stdin, `--file f` a file) |
| `review <id> --ok ["summary"]` / `--changes "summary + 1. … 2. …"` | the verdict of a review as a review comment naming the reviewed head of the item's branch; answers no question, wakes no agent (`--file f` reads the text from a file) |
| `action <id> ["name"]` | the actions of the item's status; with a name, ask the running server to run it (result in the discussion) |
| `pr <id> [--description text \| --description-file f\|-] [--force]` | push the item's branch and open its pull request (`dispatcher.pr`), URL into `pr`; with a PR already, only push; `--force` after a rebase (with a lease) |
| `view [name]` | saved views |
| `lint` | consistency: unknown values, broken references, cycles, locks, malformed or overlapping touches, dispatcher worktrees, agent, actions and pull request commands (exit 1 on errors) |
| `instructions` | the guide for agents, in Markdown |
| `projects`, `projects add [dir] [--id] [--name]`, `projects remove <id>`, `projects pin\|unpin <id>` | the registry of backlogs on this machine (`~/.config/kanban-ai/projects.yaml`), see below |
| `config [--projects f]` | configuration in a terminal UI, see below |

**Project registry:** `backlog init` registers the new backlog by itself (`--no-register` skips it); `backlog projects add` (in a project) registers an existing backlog in `$XDG_CONFIG_HOME/kanban-ai/projects.yaml` (default `~/.config/kanban-ai/projects.yaml`; elsewhere with `BACKLOG_PROJECTS` or `--projects <file>`). The file is plain YAML you can also edit by hand — `projects:` is a list of `{id?, name?, path}`, paths absolute, `~/…` or relative to the file; the id defaults to the project folder's name (the parent of a folder called `backlog`), the first project is the default one, and `pinned: true` puts a project into the board switcher's short list (`backlog projects pin|unpin <id>`, or the pin in the switcher's *All projects…*).

**Configuration TUI:** `backlog config` opens a terminal UI with two separate parts: **Global** (this machine — the project registry and the server settings) and **Project** (the `backlog.yaml` of the backlog here or of a registered project). *Project › Workflow* edits statuses (order, category, pickable), priorities, types, milestones (title, due date), the defaults, the id prefix and length and the claim lease; renaming a status also renames it in the defaults, colours and dispatcher actions (items keep the old one, `backlog lint` lists them). Pages for the other sections are on the way; until then *Edit a value…* changes any key (`claims.lease_minutes`, `statuses[1].pickable`, a YAML value; empty removes it). Nothing is written until *Review and save*, which shows the diff, checks that the file is still valid and saves after `y`, keeping comments and unknown keys; a file edited meanwhile by someone else is not overwritten. ↑↓ move, `/` filters, Enter choose, Esc back, `q` quit.

Global options are `-C <dir>` and `--json`. The agent comes from `--as` or `BACKLOG_AGENT`. **Exit codes:** 0 ok, 1 error, 2 nothing to do, 3 claim conflict, 4 not found, 64 usage. JSON fields are only ever added, never renamed.

## Architecture

A Dart pub workspace, plus the Flutter app:

```
packages/
  backlog_core/    domain, use cases, file-system adapters
  backlog_cli/     CLI adapter (args), text/JSON output, the TUI of `backlog config` (on dart_tui)
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
| `workflow` | `Workflow`, statuses and categories, `DispatcherConfig`, `AgentProfile`, port `WorkflowSource` (load, revision, edits) | – | `backlog.yaml` parser, `FileWorkflowSource` (`yaml_edit`, keeps comments; revision = content hash) |
| `projects` | `ProjectRegistry`, `ProjectEntry`, port `ProjectRegistryStore` | `ProjectService` | `projects.yaml` (`yaml_edit`, keeps comments) |
| `items` | `Item`, `ItemId`, `Checklist`, ports `ItemRepository`, `IdGenerator` | `ItemService`, `FieldChange` | Markdown codec (`yaml_edit`, keeps formatting), file-system repository |
| `claims` | `Claim` (lease), port `ClaimStore` | `ClaimService` (claim, next, heartbeat, release, drop, done) | lock files |
| `planning` | `BacklogSnapshot`, `PlannedItem`: blocked, conflicting, ready, cycles, children | `PlanningService` | – |
| `dispatch` | `DispatchPlan` (ready items → free worktrees; held items, unavailable worktrees, running agents; where an action runs), `ActionState` (status hooks), ports `AgentLauncher`, `ActionStateStore`, `ActionRequests` | `Dispatcher` (debounce, wake-up on claim expiry, auto launch, manual start/stop, actions and hooks), `LoggingLauncher` | `ProcessAgentLauncher` (detached processes, state files, heartbeat, end of run, action commands and built-ins), `WorktreeProvisioner` (worktrees on demand, cleanup), `BuiltInAction` registry, `FileActionStateStore`, `FileActionRequests` |
| `views` | `Filter`, `ViewDefinition`, `ViewEngine` | `ViewService` | YAML views |
| `validation` | `LintIssue` | `Linter` | – |
| `settings` | `ConfigDraft` (edits via `yaml_edit`, key paths, typed values), line diff, port `ConfigFile` | `ConfigEditor` (open, validate, save unless changed meanwhile) | configuration files (`backlog.yaml`, `projects.yaml`) |

`Backlog.open()` is the composition root that wires the ports to the file-system adapters. To support several users on a database, you would write other adapters (`ItemRepository`, `ClaimStore`, `WorkflowSource`) and leave the domain unchanged. The DDD is light:
- value objects
- an immutable `Item` entity
- the domain service `BacklogSnapshot`, the only place where planning state is computed

There is no event bus or event sourcing: the state lives in files and git keeps the history.

**The server** is a driving adapter. `ApiHandler` parses requests, calls the core services and maps the results through `DtoMapper` to the DTOs of `backlog_api`. `ChangeFeed` watches the folder, debounces bursts of changes and ignores `.git` and temporary files. `BacklogHost` reloads the workflow after `backlog.yaml` changes, the core's `Dispatcher` re-plans on the same change events. The server opens backlogs with an in-memory item cache: each request still lists and `stat`s the item files but parses only those whose modification time, ctime or size changed (recently written files are always re-read, because file times are coarse), so edits by agents, editors or `git` are seen without relying on the watcher; claims are always read fresh (SPEC §8). Each backlog is a `HostedProject` (host, feed, dispatcher, API); `ProjectHub` keeps them in registry order and routes `/api/p/<id>/…`, `RegistryWatcher` applies registry edits live, and `BacklogServer` is the composition root.

**The app** is split by feature (`features/board`, `features/item`, `features/projects`, `features/dispatch`). Each feature has `application/` (`ChangeNotifier` controllers without widgets, and pure logic such as `ColumnArrangement`) and `presentation/`. It depends only on the `BacklogApi` interface, which `AppScope` provides. `ProjectsController` picks the open project from the `ProjectsApi`; each project gets its own session (its `BacklogApi` in `AppScope`, theme, board), thrown away as a whole when another project is opened.

**The REST API** (`/api/…` for the default project, the same under `/api/p/<id>/…` for each project):
- `projects` (global: `[{id, name, path, error, pinned}]`); `projects/<id>`: PATCH `{pinned}` writes it into the registry
- `workflow`, `items` (`?all=true`)
- `items/<id>`: GET (with its relations and the items it waits for or holds up through `touches`), and PATCH `{changes: ["status=done"], body}`
- `items/<id>/claim|release|done`: POST `{agent, status, force}`
- `items/<id>/comments`: POST `{text, author?, question?, note?}` (the detail has `discussion`, items `needs_human`, `review` — `running` while an AI review runs — and `review_findings`)
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
| `mise run build-web` | the web app in `packages/backlog_app/build/web`: CanvasKit bundled (nothing from Google's CDN), no service worker, Brotli/gzip copies for the server (`brotli` optional) |
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
