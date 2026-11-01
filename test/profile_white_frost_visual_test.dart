import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/daily_token_usage_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/economy/application/store_purchase_service.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'package:maaso/src/features/identity/presentation/profile_page.dart';
import 'package:sembast/sembast_memory.dart';

import 'identity_test_support.dart';
import 'profile_membership_test_support.dart';

// Opt in with --dart-define=MAASO_CAPTURE_PROFILE=true. Capture each theme in a
// separate flutter test process using --plain-name 'light:' or 'dark:' to
// reproduce each preview independently.
const _capture = bool.fromEnvironment('MAASO_CAPTURE_PROFILE');
const _visualFont = 'ProfileWhiteFrostVisual';
bool _visualFontsLoaded = false;

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh'));
  });
  tearDown(() async {
    AppLocalization.updateLocale(const Locale('en'));
    await appServices.reset();
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    testWidgets('$mode: real theme keeps membership and usage separate', (
      tester,
    ) async {
      final boundary = await _mount(tester, dark: dark);
      final membership = find.byKey(const ValueKey('profile-membership-card'));
      final tokens = find.byKey(const ValueKey('profile-daily-token-card'));
      final relationship = find.byKey(
        const ValueKey('profile-relationship-entry'),
      );
      final membershipMaterial = tester
          .element(membership)
          .findAncestorWidgetOfExactType<Material>()!;
      final tokenMaterial = tester.widget<Material>(tokens);
      final context = tester.element(tokens);
      expect(identical(membershipMaterial, tokenMaterial), isFalse);
      expect(membershipMaterial.color, Theme.of(context).colorScheme.primary);
      expect(tokenMaterial.color, AppSecondaryPalette.of(context).surfaceMuted);
      expect(
        find.ancestor(of: tokens, matching: find.byWidget(membershipMaterial)),
        findsNothing,
      );
      expect(
        tester.getRect(tokens).top - tester.getRect(membership).bottom,
        closeTo(16, .01),
      );
      expect(
        tester.getRect(relationship).top,
        greaterThanOrEqualTo(tester.getRect(tokens).bottom + 16),
      );
      expect(find.text('Plus'), findsOneWidget);
      expect(find.text('12,480'), findsOneWidget);
      for (final text
          in find
              .descendant(of: membership, matching: find.byType(RichText))
              .evaluate()) {
        final paragraph = text.renderObject! as RenderParagraph;
        expect(
          paragraph.text.style?.color,
          Theme.of(context).colorScheme.onPrimary,
        );
        expect(paragraph.size.isEmpty, isFalse);
      }
      expect(
        find.byKey(const ValueKey('profile-daily-token-details')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _captureFrame(tester, boundary, '$mode-zh-top');

      await tester.tap(
        find.byKey(const ValueKey('profile-daily-token-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('输入  9,240'), findsOneWidget);
      expect(find.text('输出  3,240'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _captureFrame(tester, boundary, '$mode-zh-token-details');
      await tester.ensureVisible(
        find.byKey(const ValueKey('profile-interests-edit')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      debugDisableShadows = true;
    });
  }
}

Future<GlobalKey> _mount(WidgetTester tester, {required bool dark}) async {
  tester.view.physicalSize = const Size(390, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final profile = ProfileFixture();
  profile.identityGateway.stored = identityFixture(player: '小满');
  profile.companionGateway.value = profile.companionGateway.value.copyWith(
    interests: ['music', 'travel', 'books'],
  );
  final membership = StorePurchaseService(
    gateway: MembershipGatewayFake()..activeTier = MembershipTier.plus,
  );
  final day = DateTime(2026, 10, 26, 12);
  final setup = await tester.runAsync(() async {
    final db = await databaseFactoryMemory.openDatabase('profile-visual-$dark');
    final usage = await DailyTokenUsageService(
      database: db,
      accountScopeDigest: 'account-a',
      isCurrent: () => profile.current,
      now: () => day,
    ).init(observeLifecycle: false);
    await usage.record(
      requestId: 'visual-example',
      dispatchedAt: day,
      usage: const ReportedTokenUsage(input: 9240, output: 3240, total: 12480),
    );
    if (_capture) await _loadVisualFonts();
    return (db, usage);
  });
  final (db, usage) = setup!;
  final theme = appServices.put(ThemeService())
    ..setMode(dark ? ThemeModePreference.dark : ThemeModePreference.light);
  final base = AppTheme.build(
    theme.palette,
  ).copyWith(platform: TargetPlatform.iOS);
  final boundary = GlobalKey();
  if (_capture) {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
  }
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: _capture
            ? base.copyWith(
                textTheme: base.textTheme.apply(fontFamily: _visualFont),
                primaryTextTheme: base.primaryTextTheme.apply(
                  fontFamily: _visualFont,
                ),
              )
            : base,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 44, bottom: 24),
            disableAnimations: true,
          ),
          child: RepaintBoundary(key: boundary, child: child!),
        ),
        home: ProfilePage(
          controller: profile.controller,
          route: '/profile',
          membershipRoute: '/membership',
          membership: membership,
          tokenUsage: usage,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    membership.onClose();
    profile.close();
    usage.onClose();
    await db.close();
  });
  return boundary;
}

Future<void> _loadVisualFonts() async {
  // Register screenshot fonts once per test process.
  if (_visualFontsLoaded) return;
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  final font = File('/System/Library/Fonts/STHeiti Light.ttc');
  expect(
    await font.exists(),
    isTrue,
    reason: 'Chinese screenshot font required',
  );
  final bytes = ByteData.sublistView(await font.readAsBytes());
  for (final family in [_visualFont, 'Ahem', 'Roboto']) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
  _visualFontsLoaded = true;
}

Future<void> _captureFrame(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  if (!_capture) return;
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File(
      'build/verification/profile-white-frost-20261026/$name.png',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}
