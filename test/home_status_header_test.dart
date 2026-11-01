import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_status_header.dart';
import 'package:maaso/src/features/identity/presentation/companion_avatar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(() async {
    await appServices.reset();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'header exposes task history beside menu and profile without wallet',
    (tester) async {
      var menuTaps = 0;
      var historyTaps = 0;
      var profileTaps = 0;
      await tester.pumpWidget(
        _host(
          avatar: true,
          onToggle: () => menuTaps++,
          onHistory: () => historyTaps++,
          onProfile: () => profileTaps++,
        ),
      );
      await tester.pumpAndSettle();
      final history = find.byKey(const ValueKey('home-task-history-button'));
      final menu = find.byKey(const ValueKey('home-menu-toggle'));
      final profile = find.byKey(const ValueKey('home-profile-button'));
      expect(find.byKey(const ValueKey('home-wallet-button')), findsNothing);
      expect(find.byKey(const ValueKey('home-coin-balance')), findsNothing);
      expect(find.byKey(const ValueKey('home-status-day')), findsNothing);
      expect(find.textContaining('Day '), findsNothing);
      expect(find.byType(AppFrostedInputBackground), findsNWidgets(2));
      expect(
        tester.getSize(find.byType(AppFrostedInputBackground).first).height,
        tester.getSize(find.byType(CompanionAvatar)).height,
      );
      expect(tester.getRect(history).overlaps(tester.getRect(menu)), isFalse);
      expect(tester.getRect(history).right + 8, tester.getRect(menu).left);
      expect(tester.getRect(menu).overlaps(tester.getRect(profile)), isFalse);
      expect(tester.getSize(history), const Size(48, 48));
      expect(tester.widget<IconButton>(history).tooltip, isNotEmpty);
      expect(tester.getSize(menu), const Size(48, 48));
      expect(tester.getSize(profile), const Size(48, 48));
      await tester.tap(history);
      await tester.tap(menu);
      await tester.tap(profile);
      expect(historyTaps, 1);
      expect(menuTaps, 1);
      expect(profileTaps, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'reserved height matches large text and narrow layouts $brightness',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        for (final width in [280.0, 320.0, 375.0, 768.0]) {
          for (final scale in [1.0, 2.0]) {
            tester.view.physicalSize = Size(width, 600);
            await tester.pumpWidget(
              _host(scale: scale, brightness: brightness),
            );
            await tester.pumpAndSettle();
            final header = find.byKey(const ValueKey('home-status-header'));
            final context = tester.element(find.byType(HomeStatusHeader));
            expect(find.byKey(const ValueKey('home-status-day')), findsNothing);
            expect(
              tester
                  .getRect(find.byKey(const ValueKey('home-profile-button')))
                  .right,
              closeTo(width - 14, 0.01),
            );
            expect(
              tester.getSize(header).height,
              HomeStatusHeader.heightFor(context),
            );
            expect(
              tester.getSize(find.byKey(const ValueKey('home-menu-toggle'))),
              const Size(48, 48),
            );
            expect(tester.takeException(), isNull);
            expect(find.byType(BackdropFilter), findsNothing);
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('avatar iOS shares one native background for history and menu', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    await tester.pumpWidget(_host(avatar: true));
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    final view = tester.widget<UiKitView>(find.byType(UiKitView));
    expect(view.creationParams, {
      'dark': false,
      'group': true,
      'cornerRadius': 0.0,
    });
    expect(
      find.ancestor(of: find.byType(UiKitView), matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byType(UiKitView),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
    await tester.pumpWidget(_host(avatar: false));
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsNothing);
    expect(calls.where((call) => call.method == 'create'), hasLength(1));
    expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    await tester.pumpWidget(_host(avatar: true, highContrast: true));
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}

Widget _host({
  bool avatar = false,
  bool expanded = false,
  VoidCallback? onToggle,
  VoidCallback? onHistory,
  VoidCallback? onProfile,
  double scale = 1,
  bool highContrast = false,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: AppTheme.build(AppPalette.of(brightness, AppAccent.blue)),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        highContrast: highContrast,
      ),
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Align(
            alignment: Alignment.topCenter,
            child: HomeStatusHeader(
              avatar: avatar,
              expanded: expanded,
              onMenuToggle: onToggle ?? () {},
              onTaskHistory: onHistory ?? () {},
              onProfile: onProfile,
            ),
          ),
        ),
      ),
    ),
  ),
);
