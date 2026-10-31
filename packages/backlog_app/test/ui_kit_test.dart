import 'package:backlog_app/shared/tokens.dart';
import 'package:backlog_app/shared/ui/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tokens = BoardTokens.light;

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      // The app's real (compact) theme, so sizes are what users get.
      theme: tokens.toTheme(Brightness.light),
      home: Scaffold(body: Center(child: child)),
    ),
  );

  TextStyle? styleOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style;

  group('buttons', () {
    testWidgets('PrimaryButton sets label and icon colour explicitly from the tokens', (tester) async {
      await pump(tester, PrimaryButton(label: 'Go', icon: Icons.add, onPressed: () {}));
      expect(styleOf(tester, 'Go')?.color, tokens.onAccent);
      expect(tester.widget<Icon>(find.byIcon(Icons.add)).color, tokens.onAccent);
      expect(tester.getSize(find.byType(FilledButton)).height, BoardTokens.controlHeight);
    });

    testWidgets('disabled buttons use the faint colour and do not fire', (tester) async {
      await pump(
        tester,
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PrimaryButton(label: 'P', onPressed: null),
            SecondaryButton(label: 'S', icon: Icons.add, onPressed: null),
            LinkButton(label: 'L', onPressed: null),
          ],
        ),
      );
      expect(styleOf(tester, 'P')?.color, tokens.faint);
      expect(styleOf(tester, 'S')?.color, tokens.faint);
      expect(styleOf(tester, 'L')?.color, tokens.faint);
      expect(tester.widget<Icon>(find.byIcon(Icons.add)).color, tokens.faint);
    });

    testWidgets('SecondaryButton uses the text colour, shows its trailing widget and fires', (tester) async {
      var taps = 0;
      await pump(tester, SecondaryButton(label: 'More', trailing: const CountBadge(2), onPressed: () => taps++));
      expect(styleOf(tester, 'More')?.color, tokens.text);
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.byType(OutlinedButton));
      expect(taps, 1);
      expect(tester.getSize(find.byType(OutlinedButton)).height, BoardTokens.controlHeight);
    });

    testWidgets('LinkButton can be an accent link', (tester) async {
      await pump(tester, LinkButton(label: 'Clear', accent: true, compact: true, onPressed: () {}));
      expect(styleOf(tester, 'Clear')?.color, tokens.accent);
    });

    testWidgets('IconActionButton has a tooltip and fires', (tester) async {
      var taps = 0;
      await pump(tester, IconActionButton(tooltip: 'Reload', icon: Icons.refresh, onPressed: () => taps++));
      expect(find.byTooltip('Reload'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.refresh));
      expect(taps, 1);
    });
  });

  group('SegmentedChoice', () {
    testWidgets('reports taps and styles the pressed segments', (tester) async {
      final tapped = <String>[];
      await pump(
        tester,
        SegmentedChoice<String>(
          segments: const [
            ChoiceSegment(value: 'a', label: 'Alpha', key: ValueKey('seg-a')),
            ChoiceSegment(value: 'b', label: 'Beta', tooltip: 'The second'),
          ],
          selected: const {'b'},
          onToggle: tapped.add,
        ),
      );
      expect(styleOf(tester, 'Beta')?.color, tokens.accent);
      expect(styleOf(tester, 'Beta')?.fontWeight, FontWeight.w600);
      expect(styleOf(tester, 'Alpha')?.color, tokens.text);
      await tester.tap(find.byKey(const ValueKey('seg-a')));
      await tester.tap(find.text('Beta'));
      expect(tapped, ['a', 'b']);
      expect(find.byTooltip('The second'), findsOneWidget);
    });
  });

  group('ChoiceMenu', () {
    testWidgets('shows the value and picks another one from its menu', (tester) async {
      final selected = <String>[];
      Widget menu({bool enabled = true}) => ChoiceMenu(
        key: const ValueKey('menu'),
        options: const ['todo', 'done'],
        selected: 'todo',
        enabled: enabled,
        keyOf: (value) => ValueKey('option-$value'),
        colorOf: (value) => value == 'todo' ? Colors.red : Colors.green,
        onSelect: selected.add,
      );
      await pump(tester, menu());
      expect(find.text('todo'), findsOneWidget);
      expect(find.byKey(const ValueKey('option-done')), findsNothing, reason: 'closed until tapped');
      await tester.tap(find.byKey(const ValueKey('menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-done')));
      await tester.pumpAndSettle();
      expect(selected, ['done']);

      await pump(tester, menu(enabled: false));
      await tester.tap(find.byKey(const ValueKey('menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('option-done')), findsNothing);
    });

    testWidgets('keeps an unknown selected value visible', (tester) async {
      await pump(tester, ChoiceMenu(options: const ['a'], selected: 'legacy', onSelect: (_) {}));
      expect(find.text('legacy'), findsOneWidget);
    });
  });

  group('SectionLabel', () {
    testWidgets('is uppercase and folds only with a handler', (tester) async {
      await pump(tester, const SectionLabel('Views'));
      expect(find.text('VIEWS'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);

      var toggles = 0;
      await pump(tester, SectionLabel('Team', collapsed: true, onToggle: () => toggles++));
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      await tester.tap(find.text('TEAM'));
      expect(toggles, 1);

      await pump(tester, SectionLabel('Team', onToggle: () {}));
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
    });
  });

  group('counts', () {
    testWidgets('CountBadge is an accent pill with the number', (tester) async {
      await pump(tester, const CountBadge(3));
      expect(styleOf(tester, '3')?.color, tokens.onAccent);
      final box = tester.widget<Container>(find.byType(Container)).decoration! as BoxDecoration;
      expect(box.color, tokens.accent);
    });

    testWidgets('CountText is muted', (tester) async {
      await pump(tester, const CountText(7));
      expect(styleOf(tester, '7')?.color, tokens.muted);
    });
  });

  group('RemovableChip', () {
    testWidgets('shows its text and removes through the x', (tester) async {
      var removed = 0;
      await pump(
        tester,
        RemovableChip(text: 'label: infra', removeKey: const ValueKey('x'), onRemove: () => removed++),
      );
      expect(find.text('label: infra'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('x')));
      expect(removed, 1);
    });
  });

  group('ActionBar', () {
    List<BarAction> actions(int count, List<String> fired) => [
      for (var i = 0; i < count; i++)
        BarAction(key: ValueKey('a$i'), label: 'Action $i', onPressed: () => fired.add('a$i')),
    ];

    testWidgets('a few actions are all buttons', (tester) async {
      await pump(tester, ActionBar(actions: actions(4, [])));
      expect(find.byType(SecondaryButton), findsNWidgets(4));
      expect(find.byKey(const ValueKey('action-bar-more')), findsNothing);
    });

    testWidgets('many actions put the rest behind More…', (tester) async {
      final fired = <String>[];
      await pump(tester, ActionBar(actions: actions(6, fired)));
      expect(find.text('Action 2'), findsOneWidget);
      expect(find.text('Action 3'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('action-bar-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('a5')));
      await tester.pumpAndSettle();
      expect(fired, ['a5']);
    });
  });
}
