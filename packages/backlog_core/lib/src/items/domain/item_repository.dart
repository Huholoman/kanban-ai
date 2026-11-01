import 'item.dart';
import 'item_id.dart';

/// A file (or record) that could not be turned into an [Item].
final class LoadProblem {
  const LoadProblem(this.location, this.message);

  final String location;
  final String message;

  @override
  String toString() => '$location: $message';
}

/// Everything the repository could read, plus what it could not.
final class ItemCatalog {
  const ItemCatalog(this.items, [this.problems = const [], this.archived = const {}]);

  /// May contain duplicate ids; the linter reports them. Archived items are
  /// included, so that references to them still resolve.
  final List<Item> items;
  final List<LoadProblem> problems;

  /// Ids of the [items] stored in the archive.
  final Set<ItemId> archived;
}

/// Port for item storage. Today it is a folder of Markdown files; a server
/// with several users can implement it on top of a database.
abstract interface class ItemRepository {
  Future<ItemCatalog> load();

  /// Creates or replaces the item. Implementations should keep whatever they
  /// do not understand (formatting, comments, unknown keys) intact, and move
  /// an archived item that is no longer finished out of the archive.
  Future<void> save(Item item);

  /// Where the item is stored (a file path for the file-system adapter), so
  /// that a human or an agent can open it directly.
  Future<String?> locationOf(ItemId id);

  /// Moves the item into the archive, or back out of it ([archived] false);
  /// nothing happens when it is there already.
  Future<void> setArchived(ItemId id, {required bool archived});
}
