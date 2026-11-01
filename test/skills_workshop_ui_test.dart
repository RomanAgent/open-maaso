import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart'
    show SkillCatalog;
import 'package:maaso/src/features/skills/application/skill_store_controller.dart';
import 'package:maaso/src/features/skills/application/skills_controller.dart';
import 'package:maaso/src/features/skills/application/skill_user_groups.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/presentation/skill_store_page.dart';
import 'package:maaso/src/features/skills/presentation/skills_page.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late _SkillsController builtIn;
  late _StoreController store;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en'));
    builtIn = _SkillsController();
    store = _StoreController();
    appServices.put<SkillsController>(builtIn);
    appServices.put<SkillStoreController>(store);
  });

  tearDown(() async {
    await appServices.reset();
  });

  testWidgets('built-in local usage updates only after actual calls', (
    tester,
  ) async {
    final usage = (await tester.runAsync(() => _usage('reactive')))!;
    final skill = SkillCatalog.byId('freeform_surface')!;
    final skillName = skill.hostRouting!.skillName;
    await _mount(tester, const SkillsPage(header: SizedBox(height: 40)));
    final counter = find.byKey(
      const ValueKey('builtin-skill-group-usage-creation'),
    );
    expect(tester.widget<Text>(counter).data, 'skills.usage_no_record'.tr);
    expect(usage.forSkill(skillName).started, 0);

    await tester.runAsync(() async {
      final first = usage.start(
        skillName: skillName,
        method: skill.hostRouting!.methods.first,
        channel: SkillUsageChannel.native,
      );
      expect(first, isNotNull);
      await first!.finish(succeeded: true);
      await usage.whenSettled;
    });
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(counter).data,
      'skills.usage_count'.trParams({'count': '1'}),
    );
    expect(tester.widget<Text>(counter).data, contains('1'));
    await tester.runAsync(() async {
      final other = SkillCatalog.byId('creator')!;
      final second = usage.start(
        skillName: other.hostRouting!.skillName,
        method: other.hostRouting!.methods.first,
        channel: SkillUsageChannel.structured,
      );
      await second!.finish(succeeded: false);
      await usage.whenSettled;
    });
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(counter).data,
      'skills.usage_count'.trParams({'count': '2'}),
    );
    expect(tester.widget<Text>(counter).data, contains('2'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing, loading, or unavailable local records are not zero', (
    tester,
  ) async {
    final counter = find.byKey(
      const ValueKey('builtin-skill-group-usage-creation'),
    );
    await _mount(tester, const SkillsPage(header: SizedBox(height: 40)));
    expect(counter, findsNothing);

    final usage = (await tester.runAsync(() => _usage('states')))!;
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(counter).data, 'skills.usage_no_record'.tr);
    usage.loading.value = true;
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(counter).data, 'skills.usage_loading'.tr);
    usage.loading.value = false;
    usage.unavailable.value = true;
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(counter).data, 'skills.usage_unavailable'.tr);
    expect(
      find.text('skills.usage_count'.trParams({'count': '0'})),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('account retirement and replacement remove old usage counts', (
    tester,
  ) async {
    final first = (await tester.runAsync(() => _usage('account-a')))!;
    final skill = SkillCatalog.byId('freeform_surface')!;
    await tester.runAsync(() async {
      final attempt = first.start(
        skillName: skill.hostRouting!.skillName,
        method: skill.hostRouting!.methods.first,
        channel: SkillUsageChannel.native,
      );
      await attempt!.finish(succeeded: true);
      await first.whenSettled;
    });
    await _mount(tester, const SkillsPage(header: SizedBox(height: 40)));
    final counter = find.byKey(
      const ValueKey('builtin-skill-group-usage-creation'),
    );
    final oldLabel = 'skills.usage_count'.trParams({'count': '1'});
    expect(tester.widget<Text>(counter).data, oldLabel);

    first.retire();
    await tester.pumpAndSettle();
    expect(find.text(oldLabel), findsNothing);
    expect(tester.widget<Text>(counter).data, 'skills.usage_unavailable'.tr);
    await tester.runAsync(() => _usage('account-b', overrideAbstract: true));
    await tester.pumpAndSettle();
    expect(find.text(oldLabel), findsNothing);
    expect(tester.widget<Text>(counter).data, 'skills.usage_no_record'.tr);
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['en', 'zh']) {
    testWidgets('local Skill records fit 320px large text in $locale', (
      tester,
    ) async {
      AppLocalization.updateLocale(Locale(locale));
      final usage = (await tester.runAsync(() => _usage('large-$locale')))!;
      final skill = SkillCatalog.byId('freeform_surface')!;
      await tester.runAsync(() async {
        final attempt = usage.start(
          skillName: skill.hostRouting!.skillName,
          method: skill.hostRouting!.methods.first,
          channel: SkillUsageChannel.native,
        );
        await attempt!.finish(succeeded: true);
        await usage.whenSettled;
      });
      await _mount(
        tester,
        const SkillsPage(header: SizedBox(height: 40)),
        width: 320,
        scale: 2,
      );
      expect(
        find.text('skills.usage_count'.trParams({'count': '1'})),
        findsOneWidget,
      );
      expect('skills.usage_count'.trParams({'count': '1'}), contains('1'));
      final note = find.byKey(const ValueKey('builtin-skill-usage-note'));
      await tester.scrollUntilVisible(note, 800, maxScrolls: 100);
      await tester.pumpAndSettle();
      expect(note, findsOneWidget);
      expect(tester.widget<Text>(note).data, 'skills.usage_note'.tr);
      expect(tester.widget<Text>(note).data, isNot('skills.usage_note'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'disabled built-in abilities remain visible and can be reenabled',
    (tester) async {
      final optional = SkillCatalog.byId('web_search')!;
      expect(optional.isCore, isFalse);
      expect(optional.isComingSoon, isFalse);
      expect(SkillCatalog.available, contains(optional));
      await _mount(tester, const SkillsPage(header: SizedBox(height: 40)));
      final toggle = find.byKey(
        const ValueKey('builtin-skill-group-toggle-web_search'),
      );
      await tester.scrollUntilVisible(toggle.hitTestable(), 250);
      await tester.pumpAndSettle();
      expect(toggle.hitTestable(), findsOneWidget);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(builtIn.enabled, contains(optional.id));
      expect(toggle.hitTestable(), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(builtIn.enabled, isNot(contains(optional.id)));
      expect(toggle, findsOneWidget);
      expect(toggle.hitTestable(), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(builtIn.enabled, contains(optional.id));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('core abilities expose always-on status without a switch', (
    tester,
  ) async {
    await _mount(tester, const SkillsPage(header: SizedBox(height: 40)));
    final core = SkillUserGroupCatalog.all.first;
    final row = find.byKey(ValueKey('builtin-skill-group-${core.id}'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(Switch)),
      findsNothing,
    );
    expect(
      find.descendant(of: row, matching: find.text('skills.core_always_on'.tr)),
      findsOneWidget,
    );
    expect(find.byType(TabBar), findsNothing);
  });

  testWidgets(
    'partial projection preferences can turn off then enable together',
    (tester) async {
      builtIn.enabled.assignAll({'bluetooth'});
      await _mount(tester, const SkillsPage(header: SizedBox(height: 40)));
      final toggle = find.byKey(
        const ValueKey('builtin-skill-group-toggle-projection'),
      );
      await tester.scrollUntilVisible(toggle.hitTestable(), 300);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(find.text('skills.group.partially_enabled'.tr), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(builtIn.enabled, isEmpty);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(builtIn.enabled, {'bluetooth', 'ble_yoturetoys_projector'});
      expect(find.text('skills.group.partially_enabled'.tr), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (group, path, expectedQuery) in [
    ('persona', AppRouteCatalog.memoryWall, 'profile'),
    ('memory', AppRouteCatalog.memoryLedger, null),
  ]) {
    testWidgets(
      '$group configuration opens its existing governed destination',
      (tester) async {
        final router = GoRouter(
          initialLocation: AppRouteCatalog.skills,
          routes: [
            GoRoute(
              path: AppRouteCatalog.skills,
              builder: (_, _) => const SkillsPage(header: SizedBox(height: 40)),
            ),
            GoRoute(
              path: path,
              builder: (_, _) => const Text('Configuration destination'),
            ),
          ],
        );
        addTearDown(router.dispose);
        appNavigation.configure(router);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: appProviderContainer,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        final configure = find.byKey(
          ValueKey('builtin-skill-group-configure-$group'),
        );
        await tester.scrollUntilVisible(configure.hitTestable(), 300);
        await tester.pumpAndSettle();
        await tester.tap(configure);
        await tester.pumpAndSettle();
        expect(find.text('Configuration destination'), findsOneWidget);
        final actual = Uri.parse(appNavigation.currentRoute);
        expect(actual.path, path);
        expect(actual.queryParameters['section'], expectedQuery);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'community filters show one management state and upload on demand',
    (tester) async {
      final installed = _skill(11, 'Installed helper');
      final published = _skill(12, 'My published helper');
      store.skills.add(installed);
      store.mySkills.add(published);
      store.installations[11] = _installation(11);
      await _mount(tester, const SkillsPage(header: SizedBox(height: 40)));
      await _selectCommunity(tester);
      expect(find.text(installed.title), findsOneWidget);
      expect(find.text(published.title), findsNothing);
      expect(find.byType(TextField), findsNothing);

      final status = tester
          .widget<DropdownButtonFormField<MarketplaceSkillView>>(
            find.byKey(const ValueKey('workshop-skill-status')),
          );
      status.onChanged!(MarketplaceSkillView.published);
      await tester.pumpAndSettle();
      expect(find.text(installed.title), findsNothing);
      expect(find.text(published.title), findsOneWidget);
      expect(
        find.textContaining('skill_store.check_passed'.tr),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byKey(const ValueKey('workshop-upload-skill')));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('skill_store.version_label'.tr), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Skill cover keeps its existing square crop', (tester) async {
    const cover = 'https://cdn.example.com/skill-cover.png';
    store.skills.add(_skill(17, 'Covered Skill', coverAssetUrl: cover));
    await _mount(tester, const SkillStorePage(header: SizedBox(height: 40)));
    final image = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is NetworkImage &&
          (widget.image as NetworkImage).url == cover,
    );
    expect(image, findsOneWidget);
    expect(tester.widget<Image>(image).fit, BoxFit.cover);
    expect(tester.getSize(image), const Size(48, 48));
    expect(store.consents, isEmpty);
    expect(store.installedVersions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Skill detail keeps explicit per-permission consent', (
    tester,
  ) async {
    final skill = _skill(
      13,
      'Permission-aware helper',
      permissions: {'conversation.read', 'memory.read'},
    );
    store.skills.add(skill);
    await _mount(tester, const SkillStorePage(header: SizedBox(height: 40)));
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.tap(find.text('skill_store.view_details'.tr));
    await tester.pumpAndSettle();
    final install = find.text('skill_store.confirm_permissions_install'.tr);
    await tester.ensureVisible(install);
    await tester.tap(install);
    await tester.pumpAndSettle();
    final confirmation = find.byWidgetPredicate(
      (widget) =>
          widget is AppGlassButton &&
          widget.icon == Icons.verified_user_rounded,
    );
    expect(tester.widget<AppGlassButton>(confirmation).onPressed, isNull);
    expect(store.consents, isEmpty);
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    expect(tester.widget<AppGlassButton>(confirmation).onPressed, isNull);
    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.pumpAndSettle();
    expect(tester.widget<AppGlassButton>(confirmation).onPressed, isNotNull);
    await tester.ensureVisible(confirmation);
    await tester.tap(confirmation);
    await tester.pumpAndSettle();
    expect(store.consents.single, skill.permissions);
    expect(store.installedVersions, [13]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the permission sheet does not install the Skill', (
    tester,
  ) async {
    store.skills.add(
      _skill(15, 'Consent can be cancelled', permissions: {'memory.read'}),
    );
    await _mount(tester, const SkillStorePage(header: SizedBox(height: 40)));
    await tester.tap(find.text('skill_store.view_details'.tr));
    await tester.pumpAndSettle();
    final install = find.text('skill_store.confirm_permissions_install'.tr);
    await tester.ensureVisible(install);
    await tester.tap(install);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('common.close'.tr).last);
    await tester.pumpAndSettle();
    expect(store.consents, isEmpty);
    expect(store.installedVersions, isEmpty);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fallback search filters loaded Skills and preserves ranking', (
    tester,
  ) async {
    final trip = _skill(21, 'Trip planner', summary: 'Organize travel dates.');
    final photo = _skill(22, 'Photo helper', summary: 'Organize your images.');
    store.skills.assignAll([trip, photo]);
    store.rankedSkills.assignAll([photo, trip]);
    await _mount(tester, const SkillStorePage(header: SizedBox(height: 40)));
    final search = find.byType(TextField);
    await tester.enterText(search, 'TRIP');
    await tester.pumpAndSettle();
    expect(find.text(trip.title), findsOneWidget);
    expect(find.text(photo.title), findsNothing);
    await tester.tap(find.byKey(const ValueKey('skill-store-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('skill_store.tab.ranking'.tr).last);
    await tester.pumpAndSettle();
    expect(find.text(trip.title), findsOneWidget);
    expect(find.textContaining('#2 ·'), findsOneWidget);
    expect(tester.widget<TextField>(search).controller!.text, 'TRIP');
    await tester.enterText(search, 'images');
    await tester.pumpAndSettle();
    expect(find.text(photo.title), findsOneWidget);
    expect(find.text(trip.title), findsNothing);
    expect(find.textContaining('#1 ·'), findsOneWidget);
    expect(store.reloadCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fallback unmatched search can be cleared without reloading', (
    tester,
  ) async {
    store.skills.add(_skill(23, 'Travel planner'));
    await _mount(tester, const SkillStorePage(header: SizedBox(height: 40)));
    await tester.enterText(find.byType(TextField), 'missing-title');
    await tester.pumpAndSettle();
    expect(find.text('Travel planner'), findsNothing);
    expect(find.text('asset_store.empty'.tr), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('skill-store-empty-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Travel planner'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.text('asset_store.empty'.tr), findsNothing);
    await tester.enterText(find.byType(TextField), 'missing-again');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('skill-store-clear-search')));
    await tester.pumpAndSettle();
    expect(find.text('Travel planner'), findsOneWidget);
    expect(store.reloadCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fallback distinguishes no catalog from an offline failure', (
    tester,
  ) async {
    await _mount(tester, const SkillStorePage(header: SizedBox(height: 40)));
    expect(find.text('skill_store.empty'.tr), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'idea');
    await tester.pumpAndSettle();
    expect(find.text('skill_store.empty'.tr), findsOneWidget);
    expect(find.text('asset_store.empty'.tr), findsNothing);
    store.error.value = 'Offline fixture';
    await tester.pumpAndSettle();
    expect(find.text('skill_store.load_failed'.tr), findsOneWidget);
    expect(find.text('Offline fixture'), findsOneWidget);
    expect(find.text('asset_store.empty'.tr), findsNothing);
    expect(find.byKey(const ValueKey('skill-store-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['en', 'zh']) {
    testWidgets(
      'fallback search and sort scroll with keyboard at 320px $locale',
      (tester) async {
        AppLocalization.updateLocale(Locale(locale));
        store.skills.assignAll([
          _skill(24, 'Travel planner'),
          _skill(25, 'Photo helper'),
        ]);
        await _mount(
          tester,
          const SkillStorePage(header: SizedBox(height: 40)),
          width: 320,
          scale: 2,
        );
        final search = find.byType(TextField);
        await tester.tap(search);
        tester.view.viewInsets = const FakeViewPadding(bottom: 400);
        await tester.pumpAndSettle();
        await tester.enterText(search, 'Photo');
        await tester.pumpAndSettle();
        expect(find.text('Photo helper'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final scroll = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        );
        expect(scroll, findsOneWidget);
        final searchTop = tester.getTopLeft(search).dy;
        await tester.drag(scroll, const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(
          tester.state<ScrollableState>(scroll).position.pixels,
          greaterThan(0),
        );
        expect(tester.getTopLeft(search).dy, lessThan(searchTop));
        expect(store.reloadCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final locale in ['en', 'zh']) {
    for (final width in [320.0, 430.0]) {
      testWidgets('large-text Skill cards and workshop fit $locale at $width', (
        tester,
      ) async {
        AppLocalization.updateLocale(Locale(locale));
        store.skills.add(_skill(14, 'A useful helper with a longer title'));
        store.installations[14] = _installation(14);
        await _mount(
          tester,
          const SkillStorePage(header: SizedBox(height: 40)),
          width: width,
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(TabBar), findsNothing);
        await _mount(
          tester,
          const SkillsPage(header: SizedBox(height: 40)),
          width: width,
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        await _selectCommunity(tester);
        expect(tester.takeException(), isNull);
        expect(
          find.text('A useful helper with a longer title'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('workshop-upload-skill')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Future<SkillUsageService> _usage(
  String account, {
  bool overrideAbstract = false,
}) async {
  final database = await databaseFactoryMemory.openDatabase(
    'skill-ui-$account',
  );
  final service = await SkillUsageService(
    database: database,
    accountScopeDigest: AccountStorageScope(
      environmentKey: 'test',
      accountUuid: account,
    ).accountDigest,
    isCurrent: () => true,
  ).init(observeLifecycle: false);
  addTearDown(() async {
    await service.shutdown();
    await database.close();
  });
  return appServices.put<SkillUsageService>(
    service,
    overrideAbstract: overrideAbstract,
  );
}

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  double width = 375,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 812);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: appProviderContainer,
      child: MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: Size(width, 812),
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectCommunity(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('workshop-skill-source')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('skills.community'.tr).last);
  await tester.pumpAndSettle();
}

MarketplaceSkill _skill(
  int version,
  String title, {
  Set<String> permissions = const {},
  String summary = 'Helps with a real task and explains the result clearly.',
  String coverAssetUrl = '',
}) => MarketplaceSkill(
  skillVersionId: version,
  submissionId: version,
  skillKey: 'helper-$version',
  title: title,
  summary: summary,
  coverAssetUrl: coverAssetUrl,
  publisherId: 'author',
  versionName: '1.0.0',
  permissions: permissions,
  category: SkillCategory.reasoning,
  instruction: 'Use the requested abilities only after permission is granted.',
  examples: const [],
  manifestDigest: 'digest',
  isFree: true,
  safetyStatus: SkillSafetyStatus.passed,
  visibility: SkillVisibility.public,
);

MarketplaceInstallation _installation(int version) => MarketplaceInstallation(
  installationId: version,
  status: SkillInstallationStatus.active,
  skillVersionId: version,
  agentId: 'self',
);

class _SkillsController extends AppController implements SkillsController {
  @override
  final enabled = <String>{}.obs;
  @override
  final isApplying = false.obs;
  @override
  bool isEnabled(String id) => enabled.contains(id);
  @override
  Future<void> toggle(String id, bool on) async {
    on ? enabled.add(id) : enabled.remove(id);
  }

  @override
  bool isGroupEnabled(String groupId) => SkillUserGroupCatalog.byId(
    groupId,
  )!.optionalSpecs.every((spec) => isEnabled(spec.id));
  @override
  Future<void> toggleGroup(String groupId, bool on) async {
    final ids = SkillUserGroupCatalog.byId(
      groupId,
    )!.optionalSpecs.map((spec) => spec.id);
    on ? enabled.addAll(ids) : enabled.removeAll(ids);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StoreController extends AppController implements SkillStoreController {
  @override
  final skills = <MarketplaceSkill>[].obs;
  @override
  final rankedSkills = <MarketplaceSkill>[].obs;
  @override
  final mySkills = <MarketplaceSkill>[].obs;
  @override
  final evolutionDrafts = <SkillEvolutionDraft>[].obs;
  @override
  final isLoading = false.obs;
  @override
  final isUploading = false.obs;
  @override
  final error = RxnString();
  @override
  final selectedPackage = Rxn<File>();
  @override
  final uploadVisibility = SkillVisibility.private.obs;
  final installations = <int, MarketplaceInstallation>{}.obs;
  final consents = <Set<String>>[];
  final installedVersions = <int>[];
  int reloadCalls = 0;

  @override
  List<MarketplaceSkill> get installedSkills => skills
      .where((skill) => installationFor(skill)?.isInstalled == true)
      .toList();
  @override
  MarketplaceInstallation? installationFor(MarketplaceSkill skill) =>
      installations[skill.skillVersionId];
  @override
  bool isInstalling(MarketplaceSkill skill) => false;
  @override
  bool isChangingInstallation(MarketplaceSkill skill) => false;
  @override
  bool isLiking(MarketplaceSkill skill) => false;
  @override
  Future<void> reload({String? query}) async {
    reloadCalls++;
  }

  @override
  Future<void> install(MarketplaceSkill skill, Set<String> accepted) async {
    consents.add(Set.of(accepted));
    installedVersions.add(skill.skillVersionId);
    installations[skill.skillVersionId] = _installation(skill.skillVersionId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
