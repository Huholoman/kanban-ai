import '../../shared/errors.dart';

enum ChangeOp { set, add, remove }

/// One edit of an item field, written as `status=done`, `labels+=infra`,
/// `depends_on-=T-7f3a` or `milestone=` (clears the field).
final class FieldChange {
  const FieldChange(this.field, this.op, this.value);

  factory FieldChange.parse(String expression) {
    final match = _pattern.firstMatch(expression);
    if (match == null) {
      throw InvalidInputException('Cannot parse "$expression"; expected field=value, field+=value or field-=value.');
    }
    final op = switch (match.group(2)) {
      '+=' => ChangeOp.add,
      '-=' => ChangeOp.remove,
      _ => ChangeOp.set,
    };
    return FieldChange(match.group(1)!, op, match.group(3)!.trim());
  }

  static final _pattern = RegExp(r'^\s*([A-Za-z_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?)\s*(\+=|-=|=)(.*)$', dotAll: true);

  final String field;
  final ChangeOp op;
  final String value;

  /// The value split as a comma-separated list.
  List<String> get values => value.split(',').map((v) => v.trim()).where((v) => v.isNotEmpty).toList();

  bool get clears => op == ChangeOp.set && value.isEmpty;

  @override
  String toString() =>
      '$field${switch (op) {
        ChangeOp.set => '=',
        ChangeOp.add => '+=',
        ChangeOp.remove => '-=',
      }}$value';
}
