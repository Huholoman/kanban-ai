/// The contract for coding agents, printed by `kanban-ai instructions`.
/// A CLAUDE.md only needs to tell agents to read it.
const agentInstructions = r'''
# Working with the backlog

The backlog is a folder of Markdown files with YAML front matter
(`items/<id>-<slug>.md`), shared by every agent and worktree. Always go
through the `kanban-ai` CLI for anything that changes status, ownership or
relations; it keeps claims consistent when several agents work in parallel.
Add `--json` to any command for machine-readable output.

Identify yourself once per session, e.g. by the worktree name:

    export KANBAN_AI_AGENT=monorepo-2     # or pass --as monorepo-2

## Picking up work

    kanban-ai next                 # claims the most urgent ready item, prints it
    kanban-ai next -w labels=infra # only consider matching items
    kanban-ai ready                # just look, claim nothing
    kanban-ai claim T-7f3a         # take a specific item

`next` exits with code 2 when nothing is ready. Items whose `touches`
overlap an item in progress are not ready ("waits for T-xxxx"); they become
ready when that item is done or released. Never work on an item you
have not claimed; if `claim` reports a conflict, someone else has it.

## While working

    kanban-ai show T-7f3a          # details, dependencies, file path
    kanban-ai heartbeat T-7f3a     # renew the claim (expires after the lease)
    kanban-ai set T-7f3a branch=feat/reports
    kanban-ai set T-7f3a status=review
    kanban-ai pr T-7f3a --description "What, why, how verified"   # push the branch, open its PR
    kanban-ai set T-7f3a pr=https://github.com/org/repo/pull/42   # a PR opened by hand

`kanban-ai pr` works when `backlog.yaml` configures `dispatcher.pr`: it pushes
the item's branch (never the base branch) and opens the pull request, or only
pushes when the item has one already. Push only this way. After rebasing the
branch (e.g. to resolve conflicts with the base), `kanban-ai pr T-7f3a --force`
replaces the remote branch (with a lease; never the base branch).

Tick off the checklist of your item (`- [ ]` lines in its body) with the
CLI, not by editing the file (it may lie outside your worktree):

    kanban-ai check T-7f3a                 # the numbered checklist
    kanban-ai check T-7f3a 2               # tick item 2 (several numbers work)
    kanban-ai check T-7f3a "CSV export"    # or name it by its text
    kanban-ai uncheck T-7f3a 2

Files attached to an item (screenshots, logs, texts) are listed by `show`.
The dispatcher copies those of your item into `.kanban-ai/attachments/<id>/`
of your worktree before you start; read them there. Copy them yourself (e.g.
of another item) and attach your own with the CLI:

    kanban-ai attach T-7f3a                         # list them with their paths
    kanban-ai attach T-7f3a --export                # copy into .kanban-ai/attachments/T-7f3a/ here
    kanban-ai attach T-7f3a out/report.html         # attach files
    kanban-ai attach T-7f3a --text - --name notes.md   # a text from stdin
    kanban-ai detach T-7f3a report.html

Edit the rest of the body of your item file directly when you can (context,
plan, notes), else with the CLI (the text from a file keeps long texts out
of the command line):

    kanban-ai describe T-7f3a --file notes.md          # the description above ## Discussion
    kanban-ai describe T-7f3a --section "Acceptance criteria" --file criteria.md

Do not edit `status`, `assignee` or `id` by hand.

## Questions and comments

    kanban-ai ask T-7f3a "CSV or JSON for the export?"   # waits for a person
    kanban-ai comment T-7f3a "Done the CSV part; JSON is T-9k2d."

Both add to the `## Discussion` section at the end of the item's body
(author = your agent name). After `ask`, stop: the item needs a person and
is not ready until someone answers with a comment. When the discussion
changes what the item asks for, update the description or acceptance
criteria above `## Discussion` (`kanban-ai describe`) and say so in a comment;
never edit comments. Long texts: `kanban-ai comment T-7f3a --file note.md`
(also `ask` and `review`).

Comments marked `· review ok` / `· review changes` are reviews of the
work (`kanban-ai review T-7f3a --changes "summary, then 1. … 2. …"`, by an AI
review or a person). They wake no agent; when you are asked to fix them,
fix the numbered findings of the latest one or say in a comment why not.

## Finishing

    kanban-ai done T-7f3a                  # done, claim dropped, prints what got unblocked
    kanban-ai release T-7f3a               # give it back unfinished
    kanban-ai done T-7f3a --status cancelled

## Creating items

    kanban-ai new "Short imperative title" -t task -p p1 -m launch \
        --parent T-epic --depends-on T-7f3a -l infra --body "## Context ..."

Add `--touches lib/reports/,docs/reports.md` (paths or globs in the code
repository the work will change) when you know them, so that parallel agents
do not pick overlapping work; `kanban-ai set T-7f3a touches+=lib/x/` later.

Split work you discover into new items rather than growing the current one.
Use `depends_on` only for hard prerequisites; use `related` for context.

`--draft` makes the item a proposal (`draft: true`) that nobody takes until a
person approves it (`kanban-ai approve <id>`, or `kanban-ai discard <id>`
deletes it); under `--parent` it takes the parent's milestone. Never work on
a draft.

## Before you stop

    kanban-ai lint                 # must report no errors

Do not commit the backlog folder: the board's server commits it by itself
(`git.commit` in `backlog.yaml`). Its uncommitted changes are no problem.
''';
