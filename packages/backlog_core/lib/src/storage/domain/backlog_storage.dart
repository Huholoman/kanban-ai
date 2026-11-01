import '../../claims/domain/claim.dart';
import '../../dispatch/domain/action_run.dart';
import '../../history/domain/item_history.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_repository.dart';
import '../../views/domain/view.dart';
import '../../workflow/domain/workflow.dart';
import '../../workflow/domain/workflow_source.dart';
import 'change_source.dart';

/// Where a backlog is kept (a port): the one place that decides which
/// adapters store its configuration, items, claims, views and action
/// requests. `Backlog.connect` and the server only receive it; today there is
/// the folder of files ([FileBacklogStorage] in infrastructure, optionally
/// caching parsed items).
///
/// The contract every implementation keeps (checked by the shared tests in
/// `test/storage_contract.dart`, which each implementation runs). Several
/// storages over the same backlog stand for several processes (CLI, agents,
/// the server):
///
/// - **Atomic claims.** When any number of storages race to acquire the same
///   item ([ClaimStore.tryAcquire]) or to replace the same expired claim
///   ([ClaimStore.tryReplace]), exactly one of them wins.
/// - **No lost writes.** A finished write (item, claim, view, configuration,
///   action request) is seen by every later read of every storage, cached
///   or not; writes of different items, also concurrent ones, never undo
///   each other; a reader never sees half a write. Writes of the same item
///   replace each other (the last one wins); configuration edits with an
///   expected revision fail instead ([WorkflowSource.edit]). Each action
///   request is taken exactly once.
/// - **Nothing else changes.** A save of an item changes only that item; an
///   edit of the configuration or a view changes only what it names.
/// - **Changes reported.** A started [watch] reports every finished write
///   of any storage over the backlog (and, for files, edits made by hand or
///   by git), configuration changes marked as such.
/// - **Format kept (files).** What people edit by hand keeps its comments,
///   key order and unknown keys when the backlog writes it (item front
///   matter, `backlog.yaml`, views).
abstract interface class BacklogStorage {
  /// The folder the backlog belongs to: relative paths of its configuration
  /// (worktrees, repositories) resolve against it.
  String get root;

  /// Whether the backlog's place is there (the folder exists); a missing
  /// one may appear later.
  Future<bool> exists();

  /// A new source of the backlog's changes, bursts collected for
  /// [debounce]; call [ChangeSource.start] before relying on it.
  ChangeSource watch({Duration debounce = const Duration(milliseconds: 150)});

  /// Where the workflow configuration is kept.
  WorkflowSource get configuration;

  /// Requests to run actions, for a server's dispatcher to pick up; they do
  /// not depend on the workflow.
  ActionRequests get actionRequests;

  /// The stores of the backlog under [workflow] (its defaults and claim
  /// lease). Each call returns fresh stores: whatever they cache starts
  /// empty, so a backlog opened again after a configuration change reads
  /// everything anew.
  BacklogStores stores(Workflow workflow);

  /// [location] (from [ItemRepository.locationOf]) as shown to people: a
  /// path relative to [root] for files.
  String displayLocation(String location);
}

/// The stores of one opened backlog (see [BacklogStorage.stores]).
final class BacklogStores {
  const BacklogStores({
    required this.items,
    required this.claims,
    required this.views,
    required this.revisions,
    required this.decode,
  });

  final ItemRepository items;
  final ClaimStore claims;
  final ViewRepository views;

  /// Earlier versions of items, decoded with [decode].
  final ItemRevisions revisions;

  /// Reads an item from its stored text (for earlier versions).
  final Item Function(String text) decode;
}
