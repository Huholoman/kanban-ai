import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

import '../../../shared/debounced_changes.dart';
import '../../projects/application/projects_controller.dart';
import 'project_digest.dart';

/// The dashboard across every project the server serves: a [ProjectDigest]
/// per available project, kept live over each project's change feed, and
/// the dashboard's actions (answer a question, run an action, start or stop
/// an agent). Lives as long as the app, so the number of things that wait
/// for a person ([needsMe]) is known on every page.
class DashboardController extends ChangeNotifier {
  DashboardController(this._projects, {this.agent, Duration refreshDelay = const Duration(milliseconds: 300)})
    : _refreshDelay = refreshDelay {
    _projects.addListener(_sync);
    _sync();
  }

  final ProjectsController _projects;
  final Duration _refreshDelay;

  /// Author of answers (`&as=`); the server's default when null.
  final String? agent;

  final _sources = <String, _Source>{};
  final _notices = StreamController<String>.broadcast();
  bool _disposed = false;

  /// The project the dashboard is narrowed to; null for all of them.
  String? only;

  /// Actions under way, as `<project>/<item>`.
  Set<String> pending = const {};

  /// Success and failure messages of the actions.
  Stream<String> get notices => _notices.stream;

  /// The digests of every watched project in the registry's order (one
  /// without a project for a single backlog).
  List<ProjectDigest> get digests => [for (final source in _sources.values) ?source.digest];

  /// [digests] narrowed to [only].
  List<ProjectDigest> get shown => [
    for (final digest in digests)
      if (only == null || digest.project?.id == only) digest,
  ];

  /// Projects that could not be loaded, by name, with the error.
  List<(String, Object)> get errors => [
    for (final source in _sources.values)
      if (source.error case final error?) (source.project?.name ?? 'Backlog', error),
  ];

  /// Nothing is loaded yet.
  bool get loading => _sources.values.any((source) => source.digest == null && source.error == null);

  /// Things waiting for a person in every project (not only the shown ones).
  int get needsMe => digests.fold(0, (sum, digest) => sum + digest.needsMe);

  /// Projects that can be picked as a filter.
  List<ProjectDto> get projects => [for (final source in _sources.values) ?source.project];

  void showOnly(String? project) {
    only = project;
    notifyListeners();
  }

  /// Reloads every project now.
  Future<void> refresh() => Future.wait([for (final source in _sources.values) _load(source)]);

  bool isPending(ProjectDigest digest, String item) => pending.contains(_key(digest, item));

  /// The API of [digest]'s backlog (to open its items).
  BacklogApi apiOf(ProjectDigest digest) => _sources[digest.project?.id ?? '']!.api;

  /// Answers the open question of [item]: the agent continues by itself
  /// when the dispatcher can resume its session.
  Future<bool> answer(ProjectDigest digest, String item, String text) => _act(digest, item, (api) async {
    await api.comment(item, CommentRequest(text, author: agent));
    _notices.add('Answered $item.');
  });

  Future<bool> runAction(ProjectDigest digest, String item, String name) => _act(digest, item, (api) async {
    await api.runAction(item, name);
    _notices.add('Started "$name" for $item.');
  });

  Future<bool> startAgent(ProjectDigest digest, String item) => _act(digest, item, (api) async {
    await api.startAgent(item);
    _notices.add('Started an agent for $item.');
  });

  Future<bool> stopAgent(ProjectDigest digest, String item) => _act(digest, item, (api) async {
    await api.stopAgent(item);
    _notices.add('Stopped the agent of $item.');
  });

  Future<bool> _act(ProjectDigest digest, String item, Future<void> Function(BacklogApi api) action) async {
    final source = _sources[digest.project?.id ?? ''];
    if (source == null) return false;
    final key = _key(digest, item);
    pending = {...pending, key};
    notifyListeners();
    try {
      await action(source.api);
      await _load(source);
      return true;
    } on BacklogApiException catch (error) {
      _notices.add(error.message);
      return false;
    } finally {
      pending = {...pending}..remove(key);
      if (!_disposed) notifyListeners();
    }
  }

  static String _key(ProjectDigest digest, String item) => '${digest.project?.id ?? ''}/$item';

  /// Watches the available projects (or the single backlog), drops the
  /// ones that are gone.
  void _sync() {
    if (_disposed) return;
    final wanted = <String, ProjectDto?>{
      if (_projects.single) '': null,
      for (final project in _projects.available) project.id: project,
    };
    for (final id in [..._sources.keys]) {
      if (!wanted.containsKey(id)) _sources.remove(id)!.cancel();
    }
    if (only != null && !wanted.containsKey(only)) only = null;
    final added = <_Source>[];
    for (final MapEntry(key: id, value: project) in wanted.entries) {
      if (_sources.containsKey(id)) {
        _sources[id]!.project = project;
        continue;
      }
      final api = project == null ? _projects.api! : _projects.apiOf(id);
      final source = _sources[id] = _Source(project, api);
      source.changes = DebouncedChanges(
        api,
        (changed) => unawaited(_load(source, changed)),
        delay: _refreshDelay,
        watched: BacklogPart.values.toSet(),
      );
      added.add(source);
    }
    // Keep the registry's order.
    final ordered = {for (final id in wanted.keys) id: _sources[id]!};
    _sources
      ..clear()
      ..addAll(ordered);
    for (final source in added) {
      unawaited(_load(source));
    }
    if (added.isEmpty) notifyListeners();
  }

  /// Loads what depends on the [changed] parts of [source]'s backlog and
  /// keeps the rest of its digest; everything when null or nothing is loaded.
  Future<void> _load(_Source source, [Set<BacklogPart>? changed]) async {
    final api = source.api;
    final previous = source.digest;
    final all = changed == null || previous == null;
    bool any(Set<BacklogPart> parts) => all || changed.any(parts.contains);
    try {
      final workflowRequest = any(const {BacklogPart.workflow}) ? api.workflow() : null;
      // Items carry the AI review state of the plan.
      final itemsRequest = any(const {BacklogPart.workflow, BacklogPart.items, BacklogPart.plan})
          ? api.items(includeDone: true)
          : null;
      final planRequest = any(const {BacklogPart.workflow, BacklogPart.items, BacklogPart.plan}) ? _plan(api) : null;
      final lintRequest = any(const {BacklogPart.workflow, BacklogPart.items, BacklogPart.views}) ? api.lint() : null;
      await Future.wait<Object>([?workflowRequest, ?itemsRequest, ?planRequest, ?lintRequest]);
      // What another load brought meanwhile is newer than [previous].
      final latest = source.digest ?? previous;
      final items = await itemsRequest ?? latest!.items;
      // Questions live in item files; other changes keep the loaded ones.
      final reloadQuestions = any(const {BacklogPart.workflow, BacklogPart.items});
      final questions = <String, CommentDto>{};
      await Future.wait([
        for (final item in items)
          if (item.needsHuman && !item.isDone)
            if (!reloadQuestions && previous!.questions[item.id] != null)
              Future.value(questions[item.id] = previous.questions[item.id]!)
            else
              _question(api, item.id).then((q) => q == null ? null : questions[item.id] = q),
      ]);
      source
        ..digest = ProjectDigest(
          project: source.project,
          workflow: await workflowRequest ?? source.digest!.workflow,
          items: items,
          plan: await planRequest ?? source.digest!.plan,
          lint: await lintRequest ?? source.digest!.lint,
          questions: questions,
        )
        ..error = null;
    } catch (error) {
      source.error = error;
    }
    if (!_disposed && _sources.containsValue(source)) notifyListeners();
  }

  /// The latest question in the discussion of [item]; null when it cannot
  /// be read (the item is gone meanwhile).
  static Future<CommentDto?> _question(BacklogApi api, String item) async {
    try {
      return (await api.item(item)).discussion.where((comment) => comment.question).lastOrNull;
    } on BacklogApiException {
      return null;
    }
  }

  /// The plan; [DispatchDto.off] without a dispatcher or with an older
  /// server.
  static Future<DispatchDto> _plan(BacklogApi api) async {
    try {
      return await api.dispatch();
    } on BacklogApiException {
      return DispatchDto.off;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _projects.removeListener(_sync);
    for (final source in _sources.values) {
      source.cancel();
    }
    unawaited(_notices.close());
    super.dispose();
  }
}

/// One watched backlog.
final class _Source {
  _Source(this.project, this.api);

  ProjectDto? project;
  final BacklogApi api;
  DebouncedChanges? changes;
  ProjectDigest? digest;
  Object? error;

  void cancel() => unawaited(changes?.cancel());
}
