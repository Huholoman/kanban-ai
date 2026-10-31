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
  ItemController(this._api, this.reference, {this.agent, Duration refreshDelay = const Duration(milliseconds: 300)})
    : _refreshDelay = refreshDelay;

  final BacklogApi _api;

  /// Id (or a shortened id) of the item.
  final String reference;

  /// Who claims the item from the UI; the server default when null.
  final String? agent;
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
  Object? error;

  Stream<String> get notices => _notices.stream;

  ItemDto? get item => detail?.item;

  /// The parent's children in their order, this item among them.
  List<ItemLinkDto> get siblings => ancestors.lastOrNull?.children ?? const [];

  /// Where the item is among [siblings]; null without a parent.
  SiblingPosition? get position => switch (detail) {
    final detail? => SiblingPosition.of([for (final sibling in siblings) sibling.id], detail.item.id),
    null => null,
  };

  /// The loaded detail of a linked item, see [loadPreview].
  ItemDetailDto? preview(String id) => _previews[id];

  Future<void> start() async {
    _changes ??= DebouncedChanges(_api, () => unawaited(load(quiet: true)), delay: _refreshDelay);
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

  Future<bool> saveBody(String body) => _run(() => _api.updateItem(_id, ItemUpdateRequest(body: body)));

  Future<bool> claim() => _run(() => _api.claim(_id, ClaimRequest(agent: agent, force: true)));

  Future<bool> release() => _run(() => _api.release(_id, ClaimRequest(agent: agent, force: true)));

  Future<bool> complete() => _run(() => _api.complete(_id, ClaimRequest(agent: agent, force: true)));

  String get _id => detail?.item.id ?? reference;

  Future<bool> _run(Future<ItemDetailDto> Function() action) async {
    busy = true;
    notifyListeners();
    try {
      detail = await action();
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
