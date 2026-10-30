# CLAUDE.md — kanban-ai

Dart pub workspace (`dart pub get` in the root) plus the Flutter app outside it (`flutter pub get` in `packages/backlog_app`, own `pubspec.lock`). Nix flake in `flake.nix` builds both from the lock files. Overview, file format and architecture: `README.md`.

- `packages/backlog_core` — modules `workflow`, `items`, `claims`, `planning`, `views`, `validation`, each split into `domain/` (pure, no I/O), `application/` (use cases), `infrastructure/` (file-system adapters). Ports are interfaces in `domain/`. `src/backlog.dart` is the composition root.
- `packages/backlog_cli` — thin adapter over the core services; output in `src/render/` (text and JSON — JSON fields are only ever added, agents depend on them).
- `packages/backlog_api` — HTTP contract (DTOs, `BacklogApi` interface, `HttpBacklogApi`). Pure Dart, must compile for the web: no `dart:io`, no `backlog_core`.
- `packages/backlog_server` — shelf adapter: `ApiHandler` + `DtoMapper` (core → DTO), `ChangeFeed` (watcher → WebSocket), `BacklogServer` composition root.
- `packages/backlog_app` — Flutter web/linux. `features/<name>/application` (ChangeNotifier controllers, no widgets) and `presentation`; depends only on `BacklogApi` from `AppScope`; tests use `test/fake_api.dart`.

Rules:
- Domain code must not import `dart:io`; derived state (blocked, ready, …) belongs in `BacklogSnapshot`, not in adapters.
- Item files are edited by hand too: the codec must keep comments, key order and unknown keys (`MarkdownItemCodec.update`).
- Tools come from `mise.toml` (Flutter with its Dart, jq); Nix is system-level. Before finishing: `mise run format` and `mise run check` (format check, analysis and tests of every package). Try changes on the playground (`mise run playground`, `mise run serve`).
- Small, atomic commits: one logical change per commit (a feature, a fix, a refactor), each passing `mise run check`. Independent changes made in one session go into separate commits, never one bundle.
- `SPEC.md` (the reference) and `README.md` (the user-facing overview) must stay current: every commit that changes behaviour updates both, in the same commit as the change. Pure refactors and fixes that restore documented behaviour need no doc change.
