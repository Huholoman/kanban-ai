import '../../items/application/item_service.dart';
import '../../items/domain/item.dart';
import '../../items/domain/item_id.dart';
import '../../shared/clock.dart';
import '../../shared/errors.dart';
import '../domain/item_history.dart';

/// The history of an item (see [ItemHistory]): its committed versions, the
/// change not committed yet, its discussion and, from the dispatcher, its
/// runs.
final class HistoryService {
  HistoryService({
    required ItemService items,
    required ItemRevisions revisions,
    required Item Function(String text) decode,
    required Clock clock,
  }) : _items = items,
       _revisions = revisions,
       _decode = decode,
       _clock = clock;

  final ItemService _items;
  final ItemRevisions _revisions;
  final Item Function(String text) _decode;
  final Clock _clock;

  /// Entries of the item [reference] names, oldest first; [runs] gives its
  /// agent and action runs, [only] is one of [ItemHistory.filters].
  Future<List<HistoryEntry>> of(
    String reference, {
    Future<List<RunRecord>> Function(ItemId id)? runs,
    String? only,
  }) async {
    if (only != null && only.isNotEmpty && only != 'all' && !ItemHistory.filters.contains(only) && only != 'agents') {
      throw InvalidInputException('Unknown history filter "$only" (${ItemHistory.filters.join(', ')}).');
    }
    final item = await _items.get(reference);
    final path = await _items.locationOf(item.id);
    final revisions = path == null ? const <ItemRevision>[] : await _revisions.of(path, item.id, _decode);
    final entries = ItemHistory.build(
      current: item,
      revisions: revisions,
      runs: runs == null ? const [] : await runs(item.id),
      now: _clock.now().toUtc(),
    );
    return ItemHistory.filter(entries, only);
  }
}
