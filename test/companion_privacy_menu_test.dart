import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';
import 'package:maaso/src/desktop/presentation/companion_function_menu.dart';

void main() {
  final cases = [
    (
      'accountDeletion',
      '删除账号',
      'Delete account',
      AppRouteCatalog.accountDeletion,
    ),
    ('peopleSafety', '屏蔽名单', 'Blocked people', AppRouteCatalog.peopleSafety),
    ('privacy', '隐私与权限', 'Privacy and permissions', AppRouteCatalog.privacy),
  ];

  for (final (id, chinese, english, route) in cases) {
    testWidgets('$id is searchable and only selects its registered page', (
      tester,
    ) async {
      final selections = <CompanionMenuEntry>[];
      final entry = CompanionMenuCatalog.entries.singleWhere(
        (item) => item.destination.id == id,
      );
      expect(enUS[entry.labelKey], english);
      expect(zhCH[entry.labelKey], chinese);
      expect(entry.icon, isNot(CompanionMenuIcon.unknown));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 420,
              child: CompanionFunctionMenu(onSelected: selections.add),
            ),
          ),
        ),
      );
      expect(selections, isEmpty);
      await tester.enterText(
        find.byKey(CompanionFunctionMenu.searchFieldKey),
        id,
      );
      await tester.pump();
      final tile = find.byKey(CompanionFunctionMenu.entryKey(id));
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      expect(selections, hasLength(1));
      expect(selections.single.destination.route, route);
      expect(tester.takeException(), isNull);
    });
  }
}
