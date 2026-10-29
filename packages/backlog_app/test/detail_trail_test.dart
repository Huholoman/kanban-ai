import 'package:backlog_app/features/board/application/detail_trail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('opening from a panel replaces everything to its right', () {
    final trail = DetailTrail.empty.open('E').openFrom(0, 'S').openFrom(1, 'T');
    expect(trail.ids, ['E', 'S', 'T']);
    expect(trail.openFrom(0, 'S2').ids, ['E', 'S2']);
    expect(trail.open('X').ids, ['X'], reason: 'from the board: a new trail');
  });

  test('an item already on the trail is brought back instead of repeated', () {
    final trail = const DetailTrail(['E', 'S', 'T']);
    expect(trail.openFrom(2, 'E').ids, ['E']);
  });

  test('closing and popping', () {
    const trail = DetailTrail(['E', 'S', 'T']);
    expect(trail.closeFrom(1).ids, ['E']);
    expect(trail.pop().ids, ['E', 'S']);
    expect(DetailTrail.empty.pop(), DetailTrail.empty);
  });

  test('the rightmost panels win when space runs out', () {
    const trail = DetailTrail(['E', 'S', 'T', 'U']);
    expect(trail.firstShown(2), 2);
    expect(trail.firstShown(9), 0);
    expect(trail.nextAfter(1), 'T');
    expect(trail.nextAfter(3), isNull);
  });
}
