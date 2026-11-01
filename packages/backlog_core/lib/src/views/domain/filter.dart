import '../../items/domain/item_time.dart';
import '../../planning/domain/planned_item.dart';
import 'item_fields.dart';

/// A predicate over items, built from view files or command-line options.
sealed class Filter {
  const Filter();

  static const all = AllOf([]);

  bool matches(PlannedItem item);
}

final class AllOf extends Filter {
  const AllOf(this.parts);

  final List<Filter> parts;

  @override
  bool matches(PlannedItem item) => parts.every((p) => p.matches(item));
}

final class AnyOf extends Filter {
  const AnyOf(this.parts);

  final List<Filter> parts;

  @override
  bool matches(PlannedItem item) => parts.any((p) => p.matches(item));
}

final class Not extends Filter {
  const Not(this.inner);

  final Filter inner;

  @override
  bool matches(PlannedItem item) => !inner.matches(item);
}

/// True when any value of [field] is one of [values]; for list fields like
/// `labels` that means "contains one of". A `created` or `updated` instant
/// also matches its UTC day, so `created: 2026-10-31` finds items created
/// at any time of that day.
final class FieldIn extends Filter {
  FieldIn(this.field, Iterable<String> values) : values = values.toSet();

  static const _times = {'created', 'updated'};

  final String field;
  final Set<String> values;

  @override
  bool matches(PlannedItem item) => ItemFields.valuesOf(
    item,
    field,
  ).any((v) => values.contains(v) || (_times.contains(field) && values.contains(ItemTime.day(v))));
}

/// True when any value of [field] contains [text], ignoring case.
final class FieldContains extends Filter {
  FieldContains(this.field, String text) : text = text.toLowerCase();

  final String field;
  final String text;

  @override
  bool matches(PlannedItem item) => ItemFields.valuesOf(item, field).any((v) => v.toLowerCase().contains(text));
}

final class FieldExists extends Filter {
  const FieldExists(this.field, {this.exists = true});

  final String field;
  final bool exists;

  @override
  bool matches(PlannedItem item) => ItemFields.valuesOf(item, field).isNotEmpty == exists;
}

/// True when a `created` or `updated` time ([field]) is at most [age] ago,
/// or with [older] more than [age] ago, measured from when the snapshot was
/// taken ([PlannedItem.at]). A day from an older file counts as its
/// midnight UTC; items without the field never match.
final class FieldAge extends Filter {
  const FieldAge(this.field, this.age, {this.older = false});

  final String field;
  final Duration age;
  final bool older;

  static final _pattern = RegExp(r'^(\d+)\s*(m|min|h|d|w)$');

  /// `90m`, `24h`, `7d`, `2w`; null for anything else.
  static Duration? parseAge(String text) {
    final match = _pattern.firstMatch(text.trim().toLowerCase());
    if (match == null) return null;
    final count = int.parse(match.group(1)!);
    return switch (match.group(2)) {
      'm' || 'min' => Duration(minutes: count),
      'h' => Duration(hours: count),
      'd' => Duration(days: count),
      _ => Duration(days: 7 * count),
    };
  }

  @override
  bool matches(PlannedItem item) {
    final now = item.at ?? DateTime.now();
    return ItemFields.valuesOf(item, field).any((value) {
      final time = ItemTime.parse(value);
      if (time == null) return false;
      final ago = now.difference(time);
      return older ? ago > age : ago <= age;
    });
  }
}
