import '../../claims/domain/claim.dart';
import '../../dispatch/domain/action_run.dart';
import '../../history/domain/item_history.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_repository.dart';
import '../../views/domain/view.dart';
import '../../workflow/domain/workflow.dart';
import '../../workflow/domain/workflow_source.dart';

/// Where a backlog is kept (a port): the one place that decides which
/// adapters store its configuration, items, claims, views and action
/// requests. `Backlog.connect` and the server only receive it; today there is
/// the folder of files ([FileBacklogStorage] in infrastructure, optionally
/// caching parsed items).
abstract interface class BacklogStorage {
  /// The folder the backlog belongs to: relative paths of its configuration
  /// (worktrees, repositories) resolve against it.
  String get root;

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
