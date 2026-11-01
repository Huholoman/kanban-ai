/// The contract for coding agents, printed by `backlog instructions`.
/// A CLAUDE.md only needs to tell agents to read it.
const agentInstructions = r'''
# Working with the backlog

The backlog is a folder of Markdown files with YAML front matter
(`items/<id>-<slug>.md`), shared by every agent and worktree. Always go
through the `backlog` CLI for anything that changes status, ownership or
relations; it keeps claims consistent when several agents work in parallel.
Add `--json` to any command for machine-readable output.

Identify yourself once per session, e.g. by the worktree name:

    export BACKLOG_AGENT=monorepo-2      # or pass --as monorepo-2

## Picking up work

    backlog next                 # claims the most urgent ready item, prints it
    backlog next -w labels=infra # only consider matching items
    backlog ready                # just look, claim nothing
    backlog claim T-7f3a         # take a specific item

`next` exits with code 2 when nothing is ready. Items whose `touches`
overlap an item in progress are not ready ("waits for T-xxxx"); they become
ready when that item is done or released. Never work on an item you
have not claimed; if `claim` reports a conflict, someone else has it.

## While working

    backlog show T-7f3a          # details, dependencies, file path
    backlog heartbeat T-7f3a     # renew the claim (expires after the lease)
    backlog set T-7f3a branch=feat/reports
    backlog set T-7f3a status=review
    backlog pr T-7f3a --description "What, why, how verified"   # push the branch, open its PR
    backlog set T-7f3a pr=https://github.com/org/repo/pull/42   # a PR opened by hand

`backlog pr` works when `backlog.yaml` configures `dispatcher.pr`: it pushes
the item's branch (never the base branch) and opens the pull request, or only
pushes when the item has one already. Push only this way. After rebasing the
branch (e.g. to resolve conflicts with the base), `backlog pr T-7f3a --force`
replaces the remote branch (with a lease; never the base branch).

Tick off the checklist of your item (`- [ ]` lines in its body) with the
CLI, not by editing the file (it may lie outside your worktree):

    backlog check T-7f3a                 # the numbered checklist
    backlog check T-7f3a 2               # tick item 2 (several numbers work)
    backlog check T-7f3a "CSV export"    # or name it by its text
    backlog uncheck T-7f3a 2

Edit the rest of the body of your item file directly when you can (context,
plan, notes), else with the CLI (the text from a file keeps long texts out
of the command line):

    backlog describe T-7f3a --file notes.md          # the description above ## Discussion
    backlog describe T-7f3a --section "Acceptance criteria" --file criteria.md

Do not edit `status`, `assignee` or `id` by hand.

## Questions and comments

    backlog ask T-7f3a "CSV or JSON for the export?"   # waits for a person
    backlog comment T-7f3a "Done the CSV part; JSON is T-9k2d."

Both add to the `## Discussion` section at the end of the item's body
(author = your agent name). After `ask`, stop: the item needs a person and
is not ready until someone answers with a comment. When the discussion
changes what the item asks for, update the description or acceptance
criteria above `## Discussion` (`backlog describe`) and say so in a comment;
never edit comments. Long texts: `backlog comment T-7f3a --file note.md`
(also `ask` and `review`).

Comments marked `· review ok` / `· review changes` are reviews of the
work (`backlog review T-7f3a --changes "summary, then 1. … 2. …"`, by an AI
review or a person). They wake no agent; when you are asked to fix them,
fix the numbered findings of the latest one or say in a comment why not.

## Finishing

    backlog done T-7f3a                  # done, claim dropped, prints what got unblocked
    backlog release T-7f3a               # give it back unfinished
    backlog done T-7f3a --status cancelled

## Creating items

    backlog new "Short imperative title" -t task -p p1 -m launch \
        --parent T-epic --depends-on T-7f3a -l infra --body "## Context ..."

Add `--touches lib/reports/,docs/reports.md` (paths or globs in the code
repository the work will change) when you know them, so that parallel agents
do not pick overlapping work; `backlog set T-7f3a touches+=lib/x/` later.

Split work you discover into new items rather than growing the current one.
Use `depends_on` only for hard prerequisites; use `related` for context.

## Before you stop

    backlog lint                 # must report no errors

Do not commit the backlog folder: the board's server commits it by itself
(`git.commit` in `backlog.yaml`). Its uncommitted changes are no problem.
''';
