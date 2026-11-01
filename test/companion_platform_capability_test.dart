import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';
import 'package:maaso/src/desktop/presentation/companion_function_menu.dart';

void main() {
  testWidgets('menu marks limited actions without disabling navigation', (
    tester,
  ) async {
    CompanionMenuEntry? selected;
    final entries = CompanionMenuCatalog.entries
        .where(
          (entry) =>
              entry.destination.id == 'home' ||
              entry.destination.id == 'moments',
        )
        .toList(growable: false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 320,
            child: CompanionFunctionMenu(
              entries: entries,
              capabilities: const AppPlatformCapabilities.forPlatform(
                AppHostPlatform.web,
              ),
              onSelected: (entry) => selected = entry,
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(CompanionFunctionMenu.limitationKey('home')),
      findsOneWidget,
    );
    expect(
      find.byKey(CompanionFunctionMenu.limitationKey('moments')),
      findsNothing,
    );

    await tester.tap(find.byKey(CompanionFunctionMenu.entryKey('home')));
    expect(selected?.destination.id, 'home');
  });
}
