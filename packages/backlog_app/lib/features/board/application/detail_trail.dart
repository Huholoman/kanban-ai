/// The chain of open detail panels, left to right: an epic, the story opened
/// from it, the task opened from the story, … Pure value, so the board page
/// only decides how many panels fit.
final class DetailTrail {
  const DetailTrail([this.ids = const []]);

  static const empty = DetailTrail();

  final List<String> ids;

  bool get isEmpty => ids.isEmpty;

  String? get last => ids.isEmpty ? null : ids.last;

  /// Opened from the board: starts a new trail.
  DetailTrail open(String id) => DetailTrail([id]);

  /// Opened from the panel at [from]: replaces everything to its right. An
  /// item already on the trail (e.g. the parent link) is just brought back.
  DetailTrail openFrom(int from, String id) {
    final existing = ids.indexOf(id);
    if (existing >= 0) return DetailTrail(ids.sublist(0, existing + 1));
    return DetailTrail([...ids.take(from + 1), id]);
  }

  /// Closes the panel at [index] and everything right of it.
  DetailTrail closeFrom(int index) => DetailTrail(ids.take(index).toList());

  /// Closes the rightmost panel.
  DetailTrail pop() => isEmpty ? this : closeFrom(ids.length - 1);

  /// Index of the first panel shown when only [fit] panels have room; the
  /// rightmost ones win, earlier ones go to the breadcrumb.
  int firstShown(int fit) => (ids.length - fit).clamp(0, ids.length);

  /// The panel right of [index], i.e. which of its children is open.
  String? nextAfter(int index) => index + 1 < ids.length ? ids[index + 1] : null;

  @override
  bool operator ==(Object other) =>
      other is DetailTrail &&
      other.ids.length == ids.length &&
      Iterable<int>.generate(ids.length).every((i) => other.ids[i] == ids[i]);

  @override
  int get hashCode => Object.hashAll(ids);

  @override
  String toString() => ids.join(' › ');
}
