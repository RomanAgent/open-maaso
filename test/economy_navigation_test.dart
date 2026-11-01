import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';
import 'package:maaso/src/features/agent/application/capability/capability_registry.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/skills/app_control_skill.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';
import 'package:maaso/src/features/identity/presentation/profile_route_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test('retired wallet has no slash, capability, manifest or menu entry', () {
    for (final command in ['/wallet', '/coins', '/Maaso币', '/钱包', '/收益']) {
      expect(AppRouteCatalog.resolveCommand(command), isNull, reason: command);
      expect(
        resolveAvailableNavigationCommand(command),
        isNull,
        reason: command,
      );
    }
    expect(AppRouteCatalog.resolveCommand('/会员'), AppRouteCatalog.membership);
    expect(
      AppRouteCatalog.destinations.map((destination) => destination.id),
      isNot(contains('wallet')),
    );
    expect(AppRouteCatalog.commandList, isNot(contains('/wallet')));
    expect(availableNavigationCommandList(), isNot(contains('/wallet')));
    expect(appRoutePaths, isNot(contains('/wallet')));
    expect(
      buildNavigationCapabilities(
        navigate: (_) {},
        currentRoute: () => AppRouteCatalog.home,
      ).map((capability) => capability.id),
      isNot(contains('nav.wallet')),
    );
    expect(
      navigationManifests().map((manifest) => manifest.id),
      isNot(contains('nav.wallet')),
    );
    expect(
      CompanionMenuCatalog.entries.map((entry) => entry.destination.id),
      isNot(contains('wallet')),
    );
    expect(CompanionMenuCatalog.coverageIssues, isEmpty);
  });

  test('agent navigation schemas and page lists exclude retired wallet', () {
    final navigate = AppNavigateSkill();
    final control = AppControlSkill();
    for (final schema in [
      navigate.nativeToolSchemas!['openPage']!,
      control.nativeToolSchemas['execute']!,
    ]) {
      final page = (schema['properties'] as Map)['page'] as Map;
      expect(page['enum'], isNot(contains('wallet')));
      expect(page['enum'], containsAll(['profile', 'membership']));
    }
    for (final response in [
      navigate.methods['listPages']!([]),
      control.methods['listCapabilities']!([]),
    ]) {
      final pages = (jsonDecode(response as String) as Map)['pages'] as List;
      final ids = pages.map((page) => (page as Map)['id']);
      expect(ids, isNot(contains('wallet')));
      expect(ids, containsAll(['profile', 'membership']));
    }
  });

  test('AppNavigate refuses wallet without opening a page', () {
    final routes = <String>[];
    final registry = CapabilityRegistry()
      ..registerAll(
        buildNavigationCapabilities(
          navigate: routes.add,
          currentRoute: () => AppRouteCatalog.home,
        ),
      );
    final skill = AppNavigateSkill(registry: registry);
    final response = jsonDecode(
      skill.methods['openPage']!([
            {'page': 'wallet'},
          ])
          as String,
    );
    expect(registry.byId('nav.wallet'), isNull);
    expect(response['error'], 'unavailable_page');
    expect(response['valid'], isNot(contains('wallet')));
    expect(routes, isEmpty);
  });

  test('AppControl refuses wallet before page control can begin', () async {
    final skill = AppControlSkill();
    final response = await skill.methods['execute']!([
      {'page': 'wallet'},
    ]);
    final decoded = jsonDecode(response as String);
    expect(decoded['status'], 'error');
    expect(decoded['error'], 'unknown_page');
  });

  for (final location in ['/wallet', '/wallet?tab=earnings&amount=100']) {
    testWidgets('legacy $location redirects safely to profile', (tester) async {
      final router = createAppRouter(initialLocation: location);
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp.router(routerConfig: router)),
      );
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri,
        Uri.parse(AppRouteCatalog.profile),
      );
      expect(find.byType(ProfileRoutePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    });
  }
}
