import 'package:backlog_app/features/item/application/detail_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DetailNavigation', () {
    test('open remembers the way, back walks it in reverse', () {
      var navigation = const DetailNavigation('E-1');
      expect(navigation.canGoBack, isFalse);
      navigation = navigation.open('S-1').open('T-1');
      expect(navigation.current, 'T-1');
      expect(navigation.history, ['E-1', 'S-1']);
      navigation = navigation.back();
      expect(navigation, const DetailNavigation('S-1', ['E-1']));
      expect(navigation.back().back(), const DetailNavigation('E-1'), reason: 'back at the start stays');
    });

    test('going to the item just left is going back, the same item is no move', () {
      final navigation = const DetailNavigation('S-1').open('T-1');
      expect(navigation.open('S-1'), const DetailNavigation('S-1'));
      expect(navigation.open('T-1'), same(navigation));
    });

    test('replace swaps the item without a history entry', () {
      final navigation = const DetailNavigation('E-1').open('S-1').replace('S-2');
      expect(navigation, const DetailNavigation('S-2', ['E-1']));
    });
  });

  group('SiblingPosition', () {
    test('knows its neighbours and prints as "2 / 3"', () {
      final middle = SiblingPosition.of(['A', 'B', 'C'], 'B')!;
      expect('$middle', '2 / 3');
      expect((middle.previous, middle.next), ('A', 'C'));
      final first = SiblingPosition.of(['A', 'B', 'C'], 'A')!;
      expect((first.previous, first.next), (null, 'B'));
      expect(SiblingPosition.of(['A', 'B', 'C'], 'C')!.next, isNull);
      expect(SiblingPosition.of(['A'], 'X'), isNull);
    });
  });
}
