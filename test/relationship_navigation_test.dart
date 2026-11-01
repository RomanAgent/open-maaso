import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/features/identity/presentation/profile_page.dart';
import 'package:maaso/src/features/memory/application/memory_wall_controller.dart';
import 'package:maaso/src/features/relationship/presentation/relationship_hub_page.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';

import 'profile_membership_test_support.dart';

void main() {
  testWidgets(
    'an updated configuration destination selects Profile on the existing hub',
    (tester) async {
      Widget hub(RelationshipHubSection section) => MaterialApp(
        home: RelationshipHubPage(
          key: const ValueKey('retained-hub'),
          initialSection: section,
          sectionBuilders: {
            for (final item in RelationshipHubSection.values)
              item: (_) => Text('active-${item.name}'),
          },
        ),
      );
      await tester.pumpWidget(hub(RelationshipHubSection.memories));
      expect(find.text('active-memories'), findsOneWidget);
      await tester.pumpWidget(hub(RelationshipHubSection.profile));
      expect(find.text('active-profile'), findsOneWidget);
      expect(find.text('active-memories'), findsNothing);
    },
  );
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  testWidgets('profile opens the relationship hub and its memory ledger', (
    tester,
  ) async {
    final fixture = ProfileFixture();
    addTearDown(fixture.close);
    appServices.put(RelationshipService());
    appServices.put(MemoryWallController());
    final router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: AppRouteCatalog.profile,
      routes: [
        GoRoute(
          path: AppRouteCatalog.profile,
          builder: (_, _) => ProfilePage(
            controller: fixture.controller,
            route: AppRouteCatalog.profile,
            membershipRoute: AppRouteCatalog.membership,
          ),
        ),
        GoRoute(
          path: AppRouteCatalog.memoryWall,
          builder: (_, _) => const RelationshipHubPage(),
        ),
        GoRoute(
          path: AppRouteCatalog.memoryLedger,
          builder: (_, _) => const Scaffold(body: Text('Ledger route')),
        ),
      ],
    );
    appNavigation.configure(router);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('profile-relationship-entry'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(appNavigation.currentRoute, AppRouteCatalog.memoryWall);
    expect(find.text('relationship_hub.title'.tr), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('relationship-hub-profile')));
    await tester.pumpAndSettle();
    final ledger = find.byKey(
      const ValueKey('relationship-memory-ledger-entry'),
    );
    await tester.ensureVisible(ledger);
    await tester.pumpAndSettle();
    await tester.tap(ledger);
    await tester.pumpAndSettle();
    expect(appNavigation.currentRoute, AppRouteCatalog.memoryLedger);
    expect(find.text('Ledger route'), findsOneWidget);
    appNavigation.pop();
    await tester.pumpAndSettle();
    expect(appNavigation.currentRoute, AppRouteCatalog.memoryWall);
    expect(
      find.byKey(const ValueKey('relationship-hub-profile')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('persona follows existing state without starting settings', (
    tester,
  ) async {
    var settingsCreations = 0;
    appServices.lazyPut<AgentSettingsController>(() {
      settingsCreations++;
      throw StateError('The relationship hub must not initialize settings');
    });
    final soul = appServices.put(SoulService());
    soul.name.value = 'Sky';
    soul.notes.value = 'Enjoys quiet mornings';
    await tester.pumpWidget(
      const MaterialApp(
        home: RelationshipHubPage(
          initialSection: RelationshipHubSection.profile,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final persona = find.byKey(const ValueKey('relationship-agent-persona'));
    await tester.ensureVisible(persona);
    await tester.pumpAndSettle();
    final profileDetails = find.byKey(
      const ValueKey('relationship-agent-profile-details'),
    );
    await tester.ensureVisible(profileDetails);
    await tester.tap(profileDetails);
    await tester.pumpAndSettle();
    String personaText() => tester
        .widget<SelectableText>(
          find.descendant(of: persona, matching: find.byType(SelectableText)),
        )
        .data!;
    expect(personaText(), contains('Sky'));
    expect(personaText(), contains('Enjoys quiet mornings'));
    expect(personaText(), isNot(contains('null:00')));
    soul.notes.value = 'Enjoys evening walks';
    await tester.pump();
    expect(personaText(), contains('Enjoys evening walks'));
    expect(personaText(), isNot(contains('Enjoys quiet mornings')));
    expect(settingsCreations, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retired profile cannot open relationship data', (tester) async {
    final fixture = ProfileFixture();
    addTearDown(fixture.close);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ProfilePage(
            controller: fixture.controller,
            route: AppRouteCatalog.profile,
            membershipRoute: AppRouteCatalog.membership,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    fixture.companion.onClose();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<InkWell>(
            find.byKey(const ValueKey('profile-relationship-entry')),
          )
          .onTap,
      isNull,
    );
  });

  test('relationship aliases preserve old routes and skill reachability', () {
    for (final command in [
      '/我和 Agent',
      '/你和 Agent',
      '/memorywall',
      '/relationship',
    ]) {
      expect(
        AppRouteCatalog.resolveCommand(command),
        AppRouteCatalog.memoryWall,
      );
    }
    expect(AppRouteCatalog.resolveCommand('/我的技能'), AppRouteCatalog.skills);
    expect(
      AppRouteCatalog.resolveCommand('/记忆账本'),
      AppRouteCatalog.memoryLedger,
    );
  });
}
