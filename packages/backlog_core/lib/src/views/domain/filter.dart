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
/// `labels` that means "contains one of".
final class FieldIn extends Filter {
  FieldIn(this.field, Iterable<String> values) : values = values.toSet();

  final String field;
  final Set<String> values;

  @override
  bool matches(PlannedItem item) => ItemFields.valuesOf(item, field).any(values.contains);
}

final class FieldExists extends Filter {
  const FieldExists(this.field, {this.exists = true});

  final String field;
  final bool exists;

  @override
  bool matches(PlannedItem item) => ItemFields.valuesOf(item, field).isNotEmpty == exists;
}
