/// Where the detail panel is and how it got there: the item shown and the
/// items visited before it, for the back button. Pure value; the view keeps
/// one and swaps it on every move.
final class DetailNavigation {
  const DetailNavigation(this.current, [this.history = const []]);

  /// Id (or reference) of the item shown.
  final String current;

  /// Items shown before [current], the most recent last.
  final List<String> history;

  bool get canGoBack => history.isNotEmpty;

  /// Goes to [id] and remembers the current item for [back]. Going to the
  /// item just left is the same as going back, so that parent and child do
  /// not pile up when the user walks down and up again.
  DetailNavigation open(String id) {
    if (id == current) return this;
    if (history.isNotEmpty && history.last == id) return back();
    return DetailNavigation(id, [...history, current]);
  }

  /// Shows [id] instead of the current item without a history entry, e.g. a
  /// step to a sibling, which the sibling arrows undo themselves.
  DetailNavigation replace(String id) => id == current ? this : DetailNavigation(id, history);

  /// The item shown before; unchanged when there is none.
  DetailNavigation back() =>
      history.isEmpty ? this : DetailNavigation(history.last, history.sublist(0, history.length - 1));

  @override
  bool operator ==(Object other) =>
      other is DetailNavigation &&
      other.current == current &&
      other.history.length == history.length &&
      Iterable<int>.generate(history.length).every((i) => other.history[i] == history[i]);

  @override
  int get hashCode => Object.hash(current, Object.hashAll(history));

  @override
  String toString() => [...history, '[$current]'].join(' → ');
}

/// Position of an item among its siblings (the parent's children in their
/// order), for "Story 2 of 5" and the ‹ › arrows.
final class SiblingPosition {
  const SiblingPosition._(this._ids, this.index);

  /// Where [id] is in [siblings]; null when it is not there.
  static SiblingPosition? of(List<String> siblings, String id) {
    final index = siblings.indexOf(id);
    return index < 0 ? null : SiblingPosition._(List.unmodifiable(siblings), index);
  }

  final List<String> _ids;

  /// Zero-based.
  final int index;

  int get count => _ids.length;

  /// The sibling before, null for the first one.
  String? get previous => index > 0 ? _ids[index - 1] : null;

  /// The sibling after, null for the last one.
  String? get next => index + 1 < _ids.length ? _ids[index + 1] : null;

  /// `2 / 5`.
  @override
  String toString() => '${index + 1} / $count';
}
