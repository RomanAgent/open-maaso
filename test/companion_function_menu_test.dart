import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';
import 'package:maaso/src/desktop/presentation/companion_function_menu.dart';

void main() {
  testWidgets('menu stays within compact pet constraints', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 420,
            child: CompanionFunctionMenu(onSelected: (_) {}),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(CompanionFunctionMenu.searchFieldKey), findsOneWidget);
    expect(
      tester
          .widget<CompanionFunctionMenu>(find.byType(CompanionFunctionMenu))
          .entries
          .length,
      CompanionMenuCatalog.entries.length,
    );
  });

  testWidgets('search matches Chinese keywords and selection is semantic', (
    tester,
  ) async {
    CompanionMenuEntry? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 520,
            child: CompanionFunctionMenu(
              onSelected: (entry) => selected = entry,
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(CompanionFunctionMenu.searchFieldKey),
      '个人信息',
    );
    await tester.pump();

    final qrItem = find.byKey(CompanionFunctionMenu.entryKey('profile'));
    expect(qrItem, findsOneWidget);
    expect(
      tester.getSemantics(qrItem),
      matchesSemantics(
        isButton: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    await tester.tap(qrItem);
    expect(selected?.destination.id, 'profile');
  });

  testWidgets(
    'empty search result is announced instead of showing a blank menu',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 520,
              child: CompanionFunctionMenu(onSelected: (_) {}),
            ),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(CompanionFunctionMenu.searchFieldKey),
        'not-a-real-feature',
      );
      await tester.pump();

      expect(find.byKey(CompanionFunctionMenu.emptyStateKey), findsOneWidget);
    },
  );
}
