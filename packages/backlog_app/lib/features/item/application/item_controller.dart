import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

import '../../../shared/debounced_changes.dart';
import 'detail_navigation.dart';

/// State of one item's detail: loading, editing fields and body, and the
/// claim actions; also its surroundings for navigation (the parent chain and
/// the siblings) and previews of linked items. Reloads when the backlog
/// changes, e.g. an agent edits it.
class ItemController extends ChangeNotifier {
  ItemController(
    this._api,
    this.reference, {
    this.agent,
    this.boardMilestone,
    Duration refreshDelay = const Duration(milliseconds: 300),
  }) : _refreshDelay = refreshDelay;

  final BacklogApi _api;

  /// Id (or a shortened id) of the item.
  final String reference;

  /// Who claims the item from the UI; the server default when null.
  final String? agent;

  /// The milestone of the board the detail was opened from; the children
  /// filter starts with it ([childMilestone]).
  final String? boardMilestone;
  final Duration _refreshDelay;
  final _notices = StreamController<String>.broadcast();
  DebouncedChanges? _changes;

  ItemDetailDto? detail;
  WorkflowDto? workflow;

  /// Details of the item's ancestors, the root first (an epic, its story, …);
  /// empty without a parent.
  List<ItemDetailDto> ancestors = const [];
  final _previews = <String, ItemDetailDto>{};
  bool loading = false;

  /// True while a change is being saved.
  bool busy = false;

  /// True while a model estimates the item's touches ([suggestTouches]).
  bool suggestingTouches = false;
  Object? error;

  /// The History tab is shown instead of the comments.
  bool showHistory = false;

  /// The item's history (oldest first), loaded when [showHistory] and
  /// reloaded with the detail; null until loaded.
  List<HistoryEntryDto>? history;
  Object? historyError;

  /// Which entries [history] holds: `status`, `fields`, `comments`, `runs`;
  /// null for all.
  String? historyFilter;

  /// The milestone a person chose for the children ([filterChildren]); until
  /// then [boardMilestone] applies.
  ({String? milestone})? _childFilter;

  Stream<String> get notices => _notices.stream;

  ItemDto? get item => detail?.item;

  /// The parent's children in their order, this item among them.
  List<ItemLinkDto> get siblings => ancestors.lastOrNull?.children ?? const [];

  /// Where the item is among [siblings]; null without a parent.
  SiblingPosition? get position => switch (detail) {
    final detail? => SiblingPosition.of([for (final sibling in siblings) sibling.id], detail.item.id),
    null => null,
  };

  /// The milestones of the item's children, in the workflow's order (others
  /// after them by name); the children can be filtered when there are two or
  /// more.
  List<String> get childMilestones {
    final present = {for (final child in detail?.children ?? const <ItemLinkDto>[]) ?child.milestone};
    final order = [for (final milestone in workflow?.milestones ?? const <MilestoneDto>[]) milestone.id];
    return [
      for (final milestone in order)
        if (present.contains(milestone)) milestone,
      ...present.where((milestone) => !order.contains(milestone)).toList()..sort(),
    ];
  }

  /// The milestone the children are filtered by — those of it and those
  /// without a milestone are shown, as an epic run limited to it takes them —
  /// or null for all of them (also when there is nothing to choose from).
  String? get childMilestone {
    final milestones = childMilestones;
    if (milestones.length < 2) return null;
    final chosen = _childFilter == null ? boardMilestone : _childFilter!.milestone;
    return milestones.contains(chosen) ? chosen : null;
  }

  /// Filters the children by [milestone] (null: all), see [childMilestone].
  void filterChildren(String? milestone) {
    _childFilter = (milestone: milestone);
    notifyListeners();
  }

  /// The children [childMilestone] lets through.
  List<ItemLinkDto> get shownChildren {
    final children = detail?.children ?? const <ItemLinkDto>[];
    final milestone = childMilestone;
    return milestone == null
        ? children
        : [
            for (final child in children)
              if (child.milestone == null || child.milestone == milestone) child,
          ];
  }

  /// The loaded detail of a linked item, see [loadPreview].
  ItemDetailDto? preview(String id) => _previews[id];

  Future<void> start() async {
    _changes ??= DebouncedChanges(
      _api,
      (_) => unawaited(load(quiet: true)),
      delay: _refreshDelay,
      watched: const {BacklogPart.workflow, BacklogPart.items},
    );
    await load();
  }

  Future<void> load({bool quiet = false}) async {
    if (!quiet) {
      loading = true;
      notifyListeners();
    }
    try {
      workflow ??= await _api.workflow();
      final loaded = detail = await _api.item(reference);
      ancestors = await _ancestorsOf(loaded);
      if (showHistory) await _loadHistory();
      for (final id in _previews.keys.toList()) {
        try {
          _previews[id] = await _api.item(id);
        } on BacklogApiException {
          _previews.remove(id); // deleted meanwhile
        }
      }
      error = null;
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Shows the History tab (and loads it) or the comments.
  Future<void> setShowHistory(bool show) async {
    if (showHistory == show) return;
    showHistory = show;
    notifyListeners();
    if (show) await _refreshHistory();
  }

  /// Keeps only the history entries [only] names (see [historyFilter]).
  Future<void> filterHistory(String? only) async {
    if (historyFilter == only) return;
    historyFilter = only;
    history = null;
    notifyListeners();
    await _refreshHistory();
  }

  Future<void> _refreshHistory() async {
    await _loadHistory();
    notifyListeners();
  }

  Future<void> _loadHistory() async {
    try {
      history = await _api.history(_id, only: historyFilter);
      historyError = null;
    } catch (e) {
      historyError = e;
    }
  }

  /// Loads the detail of a linked item (a child expanded in the list), kept
  /// up to date with the item's own detail.
  Future<void> loadPreview(String id) async {
    try {
      _previews[id] = await _api.item(id);
    } catch (e) {
      _notices.add('$e');
    }
    notifyListeners();
  }

  /// Walks up the parent links; stops at a missing parent or a cycle.
  Future<List<ItemDetailDto>> _ancestorsOf(ItemDetailDto detail) async {
    final chain = <ItemDetailDto>[];
    final seen = {detail.item.id};
    var parent = detail.parent;
    while (parent != null && !parent.isMissing && seen.add(parent.id)) {
      final loaded = await _api.item(parent.id);
      chain.insert(0, loaded);
      parent = loaded.parent;
    }
    return chain;
  }

  /// Applies edits in the CLI syntax, see [ItemUpdateRequest].
  Future<bool> change(List<String> changes) => _run(() => _api.updateItem(_id, ItemUpdateRequest(changes: changes)));

  Future<bool> set(String field, Object? value) => change([ItemUpdateRequest.set(field, value)]);

  /// A model's estimate of the item's touches (`touches.suggest`), for a
  /// person to confirm before it is saved; null when it failed (a notice
  /// says why).
  Future<TouchesSuggestionDto?> suggestTouches() async {
    suggestingTouches = true;
    notifyListeners();
    try {
      return await _api.suggestTouches(_id);
    } catch (e) {
      _notices.add('$e');
      return null;
    } finally {
      suggestingTouches = false;
      notifyListeners();
    }
  }

  Future<bool> saveBody(String body) => _run(() => _api.updateItem(_id, ItemUpdateRequest(body: body)));

  /// Adds [text] to the item's discussion, written by [agent] (the server's
  /// user when null).
  Future<bool> comment(String text, {bool note = false}) =>
      _run(() => _api.comment(_id, CommentRequest(text, author: agent, note: note)));

  /// Attaches [files] one after the other (a taken name gets `-2`, …);
  /// those larger than the server accepts are refused with a notice. True
  /// when all were attached.
  Future<bool> attach(List<(String name, List<int> content)> files) async {
    var all = true;
    for (final (name, content) in files) {
      if (content.length > AttachmentDto.maxSize) {
        _notices.add(
          '$name is larger than ${AttachmentDto.maxSize ~/ (1024 * 1024)} MiB, the most an attachment may have.',
        );
        all = false;
        continue;
      }
      all &= await _run(() => _api.attach(_id, name, content));
    }
    return all;
  }

  /// Deletes the attachment [name].
  Future<bool> detach(String name) => _run(() => _api.detach(_id, name));

  /// Where the browser opens the attachment [name] (or saves it with
  /// [download]).
  Uri attachmentUri(String name, {bool download = false}) => _api.attachmentUri(_id, name, download: download);

  Future<bool> claim() => _run(() => _api.claim(_id, ClaimRequest(agent: agent, force: true)));

  Future<bool> release() => _run(() => _api.release(_id, ClaimRequest(agent: agent, force: true)));

  Future<bool> complete() => _run(() => _api.complete(_id, ClaimRequest(agent: agent, force: true)));

  String get _id => detail?.item.id ?? reference;

  Future<bool> _run(Future<ItemDetailDto> Function() action) async {
    busy = true;
    notifyListeners();
    try {
      detail = await action();
      if (showHistory) await _loadHistory();
      return true;
    } catch (e) {
      _notices.add('$e');
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_notices.close());
    super.dispose();
  }
}
