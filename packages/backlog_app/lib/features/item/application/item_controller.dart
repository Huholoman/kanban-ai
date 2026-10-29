import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/foundation.dart';

import '../../../shared/debounced_changes.dart';

/// State of one item's detail: loading, editing fields and body, and the
/// claim actions. Reloads when the backlog changes, e.g. an agent edits it.
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
  bool loading = false;

  /// True while a change is being saved.
  bool busy = false;
  Object? error;

  Stream<String> get notices => _notices.stream;

  ItemDto? get item => detail?.item;

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
      detail = await _api.item(reference);
      error = null;
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
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
