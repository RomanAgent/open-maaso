import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_status_header.dart';
import 'package:maaso/src/features/identity/presentation/companion_avatar.dart';

void main() {
  tearDown(() => appServices.reset());
  testWidgets(
    'menu and avatar remain separate after the wallet moves into personal information',
    (tester) async {
      var profile = 0, menu = 0;
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(
            AppPalette.of(Brightness.light, AppAccent.blue),
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(14),
              child: HomeStatusHeader(
                avatar: false,
                expanded: false,
                onTaskHistory: () {},
                onMenuToggle: () => menu++,
                onProfile: () => profile++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final avatar = find.byKey(const ValueKey('home-profile-button'));
      final setting = find.byKey(const ValueKey('home-menu-toggle'));
      expect(find.byKey(const ValueKey('home-wallet-button')), findsNothing);
      expect(
        tester.getRect(avatar).left,
        greaterThan(tester.getRect(setting).right),
      );
      expect(
        find.descendant(of: avatar, matching: find.byType(CompanionAvatar)),
        findsOneWidget,
      );
      expect(tester.getSize(avatar), const Size(48, 48));
      await tester.tap(setting);
      await tester.tap(avatar);
      expect(profile, 1);
      expect(menu, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
