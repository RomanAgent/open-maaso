import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/installed_prompt_skill_adapter.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/skills/application/skill_store_controller.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/presentation/skill_store_page.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late _StoreController store;
  var serial = 0;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en'));
    store = _StoreController();
    appServices.put<SkillStoreController>(store);
  });
  tearDown(() => appServices.reset());

  Future<SkillUsageService> mountUsage(
    String account, {
    bool replace = false,
  }) async {
    final database = await databaseFactoryMemory.openDatabase(
      'community-usage-${++serial}',
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
      overrideAbstract: replace,
    );
  }

  Future<void> record(SkillUsageService usage, MarketplaceSkill skill) async {
    final attempt = usage.start(
      skillName: promptSkillUsageKey(
        InstalledPromptSkillAdapter.descriptorIdForSkill(skill),
      )!,
      method: 'applyPrompt',
      channel: SkillUsageChannel.prompt,
    );
    await attempt!.finish(succeeded: true);
    await usage.whenSettled;
  }

  testWidgets(
    'installed cards react only to their own dispatched prompt usage',
    (tester) async {
      final first = _skill(21, 'selected-help');
      final other = _skill(22, 'other-help');
      store.skills.addAll([first, other]);
      final usage = (await tester.runAsync(() => mountUsage('a')))!;
      await _mount(tester);
      final firstCounter = find.byKey(
        const ValueKey('community-skill-usage-21'),
      );
      final otherCounter = find.byKey(
        const ValueKey('community-skill-usage-22'),
      );
      expect(
        tester.widget<Text>(firstCounter).data,
        'skills.prompt_usage_no_record'.tr,
      );
      expect(
        tester.widget<Text>(otherCounter).data,
        'skills.prompt_usage_no_record'.tr,
      );
      await tester.runAsync(() => record(usage, first));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(firstCounter).data,
        'skills.prompt_usage_count'.trParams({'count': '1'}),
      );
      expect(
        tester.widget<Text>(otherCounter).data,
        'skills.prompt_usage_no_record'.tr,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('upgrades preserve stable usage and account changes replace it', (
    tester,
  ) async {
    final first = _skill(23, 'stable-help');
    store.skills.add(first);
    final oldUsage = (await tester.runAsync(() => mountUsage('a')))!;
    await tester.runAsync(() => record(oldUsage, first));
    await _mount(tester);
    final updated = _skill(24, 'stable-help');
    store.skills.assignAll([updated]);
    await tester.pumpAndSettle();
    final counter = find.byKey(const ValueKey('community-skill-usage-24'));
    expect(
      tester.widget<Text>(counter).data,
      'skills.prompt_usage_count'.trParams({'count': '1'}),
    );
    oldUsage.retire();
    final nextUsage = (await tester.runAsync(
      () => mountUsage('b', replace: true),
    ))!;
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(counter).data,
      'skills.prompt_usage_no_record'.tr,
    );
    await tester.runAsync(() => record(nextUsage, updated));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(counter).data,
      'skills.prompt_usage_count'.trParams({'count': '1'}),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable or missing records are never fabricated as zero', (
    tester,
  ) async {
    store.skills.add(_skill(25, 'helper'));
    await _mount(tester);
    final counter = find.byKey(const ValueKey('community-skill-usage-25'));
    expect(counter, findsNothing);
    final usage = (await tester.runAsync(() => mountUsage('a')))!;
    await tester.pumpAndSettle();
    usage.unavailable.value = true;
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(counter).data, 'skills.usage_unavailable'.tr);
    usage.unavailable.value = false;
    usage.loading.value = true;
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(counter).data, 'skills.usage_loading'.tr);
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['en', 'zh']) {
    testWidgets(
      'prompt usage and explanation fit large text at 320px $locale',
      (tester) async {
        AppLocalization.updateLocale(Locale(locale));
        final skill = _skill(26, 'a-helpful-community-skill');
        store.skills.add(skill);
        final usage = (await tester.runAsync(() => mountUsage('a')))!;
        await tester.runAsync(() => record(usage, skill));
        await _mount(tester, width: 320, scale: 2);
        final counter = find.byKey(const ValueKey('community-skill-usage-26'));
        expect(
          tester.widget<Text>(counter).data,
          'skills.prompt_usage_count'.trParams({'count': '1'}),
        );
        expect(
          tester.widget<Text>(counter).data,
          isNot(contains('skills.prompt_usage')),
        );
        await tester.scrollUntilVisible(
          find.text('skills.prompt_usage_note'.tr),
          250,
        );
        await tester.pumpAndSettle();
        expect(find.text('skills.prompt_usage_note'.tr), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _mount(
  WidgetTester tester, {
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
        home: const Scaffold(body: MarketplaceMySkillsView()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MarketplaceSkill _skill(int version, String key) => MarketplaceSkill(
  skillVersionId: version,
  submissionId: version,
  skillKey: key,
  title: 'Community helper $version',
  summary: 'A user-authorized prompt capability.',
  coverAssetUrl: '',
  publisherId: 'community-author',
  versionName: '1.0.0',
  permissions: const {},
  category: SkillCategory.reasoning,
  instruction: 'Help with the requested task.',
  examples: const [],
  manifestDigest: 'digest',
  isFree: true,
  safetyStatus: SkillSafetyStatus.passed,
  visibility: SkillVisibility.public,
);

class _StoreController extends AppController implements SkillStoreController {
  @override
  final skills = <MarketplaceSkill>[].obs;
  @override
  final mySkills = <MarketplaceSkill>[].obs;
  @override
  final evolutionDrafts = <SkillEvolutionDraft>[].obs;
  @override
  final isLoading = false.obs;
  @override
  final error = RxnString();
  @override
  List<MarketplaceSkill> get installedSkills => skills.toList();
  @override
  MarketplaceInstallation? installationFor(MarketplaceSkill skill) =>
      MarketplaceInstallation(
        installationId: skill.skillVersionId,
        status: SkillInstallationStatus.active,
        skillVersionId: skill.skillVersionId,
        agentId: 'self',
      );
  @override
  Future<void> reload({String? query}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
