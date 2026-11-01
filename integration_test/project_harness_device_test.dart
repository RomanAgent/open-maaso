import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maaso/main.dart' as app;
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/presentation/privacy_page.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';

/// Real account startup and visible navigation only. No fabricated privacy
/// records, model invocation, consent write or real project deletion occurs.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iPhone privacy and secondary page navigation', (tester) async {
    expect(Platform.isIOS, isTrue);
    binding.reportData = {
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'profileMode': kProfileMode,
      'syntheticAccount': false,
      'modelInvocationsFromTest': 0,
      'consentWritesFromTest': 0,
      'checks': <String>[],
    };
    final checks = binding.reportData!['checks']! as List<String>;

    Future<void> until(bool Function() ready, String label) async {
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: label);
    }

    Future<void> capture(String name) async {
      await tester.pump(const Duration(milliseconds: 350));
      final image = await binding.takeScreenshot(name);
      expect(image.length, greaterThan(4096));
    }

    Future<void> openMenuItem(String label) async {
      final toggle = find.byKey(const ValueKey('home-menu-toggle'));
      await until(() => toggle.evaluate().isNotEmpty, 'home menu mounted');
      await tester.tap(toggle);
      final item = find.text(label);
      await until(() => item.evaluate().isNotEmpty, 'menu item visible');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.ensureVisible(item.last);
      await tester.tap(item.last);
      await tester.pump(const Duration(milliseconds: 350));
    }

    app.main();
    await until(
      () =>
          appServices.maybeFind<PrivacyService>()?.hasAccount == true &&
          find.byKey(const ValueKey('home-menu-toggle')).evaluate().isNotEmpty,
      'existing account and home must become ready',
    );
    checks.add('real_account_home_ready');
    await openMenuItem('settings.title'.tr);
    await until(
      () => find.byType(AgentSettingsPage).evaluate().isNotEmpty,
      'settings opened through home menu',
    );
    checks.add('settings_menu_navigation');
    final privacyEntry = find.text('settings.privacy_policy'.tr);
    await tester.scrollUntilVisible(
      privacyEntry.first,
      350,
      scrollable: find
          .descendant(
            of: find.byType(AgentSettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 30,
    );
    await tester.tap(privacyEntry.first);
    await until(
      () => find.byType(PrivacyPage).evaluate().isNotEmpty,
      'privacy page opened',
    );
    final privacy = appServices.find<PrivacyService>();
    expect(privacy.canEnterOnlineFeatures, isTrue);
    binding.reportData!['usedDefaultPrivacyAvailability'] =
        privacy.usesDefaultAvailability;
    final proceed = find.byKey(const Key('privacy-continue'));
    await until(() => proceed.evaluate().isNotEmpty, 'continue is available');
    await tester.ensureVisible(proceed);
    await capture('iphone-privacy-available');
    checks.add('privacy_available_without_writing_choices');
    await tester.tap(proceed);
    await until(
      () =>
          find.byKey(const ValueKey('home-menu-toggle')).evaluate().isNotEmpty,
      'privacy continue returns home',
    );
    checks.add('privacy_continue_home');
    await openMenuItem('widgets.title'.tr);
    await until(
      () => find.byType(WidgetsHubPage).evaluate().isNotEmpty,
      'applets secondary page opened',
    );
    await capture('iphone-applets');
    checks.add('applets_menu_navigation');
    final mine = find.byKey(const ValueKey('applet-hub-mine'));
    await tester.tap(mine);
    await until(
      () =>
          Uri.parse(appNavigation.currentRoute).path ==
          AppRouteCatalog.myApplets,
      'saved applets page opened',
    );
    await capture('iphone-my-applets');
    checks.add('saved_applets_navigation');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
