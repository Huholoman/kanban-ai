import 'item_id.dart';

/// Manual order by `rank` (lower first, unranked items after all ranked
/// ones): the ranks that move an item to a place in a list.
abstract final class ItemRank {
  /// Distance between the ranks given to neighbours without one.
  static const step = 1024;

  /// The new ranks that put [moved] at its position in [order] (ids with
  /// their current ranks, in the order wanted, e.g. a board column after a
  /// drop; ranked items ascending, then unranked ones, as a view sorted by
  /// `rank` lists them). Only the items whose rank changes are returned:
  /// usually [moved] alone, a whole number between its neighbours; the
  /// unranked items above it as well when it lands among them; the ranked
  /// items of [order] up to its first unranked one, renumbered by [step],
  /// when no whole number is left between the neighbours.
  static Map<ItemId, num> place(List<(ItemId, num?)> order, ItemId moved) {
    final at = order.indexWhere((entry) => entry.$1 == moved);
    if (at < 0) throw ArgumentError.value(moved, 'moved', 'not in the order');
    final before = order.sublist(0, at);
    final after = order.sublist(at + 1);

    // Unranked items above it: rank them in the order shown, then it.
    final firstUnranked = before.indexWhere((entry) => entry.$2 == null);
    if (firstUnranked >= 0) {
      final base = firstUnranked == 0 ? 0 : before[firstUnranked - 1].$2!;
      return _changes(order, {
        for (final (i, (id, _)) in [...before.skip(firstUnranked), order[at]].indexed) id: base + step * (i + 1),
      });
    }

    final low = before.isEmpty ? null : before.last.$2;
    final high = after.isEmpty ? null : after.first.$2;
    final current = order[at].$2;
    if (current != null && (low == null || low < current) && (high == null || current < high)) return const {};
    final num rank;
    if (high == null) {
      rank = low == null ? step : low.floor() + step;
    } else if (low == null) {
      rank = high.ceil() - step;
    } else {
      final middle = ((low + high) / 2).floor();
      if (low < middle && middle < high) {
        rank = middle;
      } else {
        return _changes(order, {
          for (final (i, (id, _)) in [...before, order[at], ...after.takeWhile((entry) => entry.$2 != null)].indexed)
            id: step * (i + 1),
        });
      }
    }
    return _changes(order, {moved: rank});
  }

  static Map<ItemId, num> _changes(List<(ItemId, num?)> order, Map<ItemId, num> ranks) {
    final current = {for (final (id, rank) in order) id: rank};
    return {
      for (final MapEntry(key: id, value: rank) in ranks.entries)
        if (current[id] != rank) id: rank,
    };
  }
}
