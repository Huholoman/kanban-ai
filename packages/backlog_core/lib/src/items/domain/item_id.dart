import 'dart:math';

import '../../shared/errors.dart';

/// Stable identity of an item, e.g. `T-7f3a`. Never changes once assigned,
/// not even when the title or the file name does.
final class ItemId implements Comparable<ItemId> {
  factory ItemId(String value) {
    final trimmed = value.trim();
    if (!_pattern.hasMatch(trimmed)) {
      throw InvalidInputException('Invalid item id "$value".');
    }
    return ItemId._(trimmed);
  }

  const ItemId._(this.value);

  static final _pattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$');

  final String value;

  @override
  bool operator ==(Object other) => other is ItemId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  int compareTo(ItemId other) => value.compareTo(other.value);

  @override
  String toString() => value;
}

/// Turns what a human or an agent typed (`T-7f3a`, `7f3a`, `t-7f`) into an id.
abstract final class ItemReference {
  static ItemId resolve(String reference, Iterable<ItemId> known) {
    final wanted = reference.trim().toLowerCase();
    if (wanted.isEmpty) {
      throw const InvalidInputException('Empty item reference.');
    }
    for (final id in known) {
      if (id.value.toLowerCase() == wanted) return id;
    }
    final candidates = known.where((id) {
      final full = id.value.toLowerCase();
      final dash = full.indexOf('-');
      final suffix = dash < 0 ? full : full.substring(dash + 1);
      return full.startsWith(wanted) || suffix.startsWith(wanted);
    }).toList()..sort();
    if (candidates.length == 1) return candidates.single;
    if (candidates.isEmpty) {
      throw NotFoundException('No item matches "$reference".');
    }
    throw AmbiguousReferenceException(
      '"$reference" matches ${candidates.length} items: ${candidates.join(', ')}.',
      candidates.map((id) => id.value).toList(),
    );
  }
}

/// Port for allocating ids of new items.
abstract interface class IdGenerator {
  ItemId next();
}

/// Short random ids (`T-7f3a`). Random rather than sequential so that agents
/// working in parallel never allocate the same id.
final class RandomIdGenerator implements IdGenerator {
  RandomIdGenerator({required this.prefix, required this.length, Random? random}) : _random = random ?? Random.secure();

  /// Without 0/o, 1/l/i to stay readable when spoken or typed.
  static const alphabet = '23456789abcdefghjkmnpqrstuvwxyz';

  final String prefix;
  final int length;
  final Random _random;

  @override
  ItemId next() {
    final suffix = List.generate(length, (_) => alphabet[_random.nextInt(alphabet.length)]).join();
    return ItemId('$prefix-$suffix');
  }
}
