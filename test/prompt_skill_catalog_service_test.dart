import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/learned_skill.dart';
import 'package:maaso/src/core/services/learned_skill_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_catalog_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';

void main() {
  setUp(() async {
    appServices.testMode = true;
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test('warm is non-blocking and atomically hot-swaps a snapshot', () async {
    final cards = Completer<List<InstalledSkillCard>>();
    final service = _service((_) => cards.future);
    final before = service.snapshotForAgent('self');
    var completed = false;

    final warm = service
        .warmAgent('self', locale: AppLocale.en)
        .whenComplete(() => completed = true);
    await Future<void>.delayed(Duration.zero);

    expect(completed, isFalse);
    expect(identical(service.snapshotForAgent('self'), before), isTrue);

    cards.complete([_card(id: 1, marker: 'WARMED_MARKER')]);
    await warm;

    expect(completed, isTrue);
    expect(
      service.snapshotForAgent('self').entries.single.promptFragment,
      contains('WARMED_MARKER'),
    );
  });

  test('learned RxList changes atomically refresh known agents', () async {
    final service = _service((_) async => const <InstalledSkillCard>[]);
    final learned = appServices.find<LearnedSkillService>();
    service.snapshotForAgent('self');
    final revisions = <String>[];
    final subscription = service.updates.listen(
      (update) => revisions.add(update.snapshot.revision),
    );

    learned.skills.assignAll([
      LearnedSkill(
        id: 'favorite_move',
        name: 'Favorite move',
        triggers: const <String>['do my favorite move'],
        steps: const <LearnedStep>[],
        summary: 'Performs a favorite move.',
      ),
    ]);

    final updated = service.snapshotForAgent('self');
    expect(updated.entries, hasLength(1));
    expect(updated.entries.single.source, PromptSkillSource.learned);
    expect(updated.entries.single.descriptor.id, startsWith('learned:'));

    learned.skills.clear();
    expect(service.snapshotForAgent('self').entries, isEmpty);
    expect(revisions, hasLength(2));
    await subscription.cancel();
  });

  test('locale generation rejects stale cross-agent refreshes', () async {
    final staleEnglish = Completer<List<InstalledSkillCard>>();
    final latestChinese = Completer<List<InstalledSkillCard>>();
    var selfLoads = 0;
    final service = _service((agentId) {
      if (agentId == 'self') {
        selfLoads++;
        if (selfLoads == 1) {
          return Future.value([_card(id: 1, marker: 'EN_INSTALLED')]);
        }
        return staleEnglish.future;
      }
      return latestChinese.future;
    });
    final learned = appServices.find<LearnedSkillService>();
    learned.skills.assignAll([
      LearnedSkill(
        id: 'locale_probe',
        name: 'Locale probe',
        triggers: const <String>[],
        steps: const <LearnedStep>[],
        summary: '',
      ),
    ]);
    await service.refreshInstalled('self', locale: AppLocale.en);
    expect(
      service
          .snapshotForAgent('self')
          .entries
          .any((entry) => entry.promptFragment.contains('EN_INSTALLED')),
      isTrue,
    );

    final oldRefresh = service.refreshInstalled('self', locale: AppLocale.en);
    final newRefresh = service.refreshInstalled('peer', locale: AppLocale.zh);

    final invalidated = service.snapshotForAgent('self');
    expect(
      invalidated.entries.where(
        (entry) => entry.source == PromptSkillSource.marketplace,
      ),
      isEmpty,
    );
    expect(invalidated.entries.single.promptFragment, contains('暂无描述'));
    expect(
      invalidated.entries.single.promptFragment,
      isNot(contains('no description')),
    );

    staleEnglish.complete([_card(id: 2, marker: 'STALE_ENGLISH')]);
    await oldRefresh;
    expect(
      service
          .snapshotForAgent('self')
          .entries
          .any((entry) => entry.promptFragment.contains('STALE_ENGLISH')),
      isFalse,
    );

    latestChinese.complete([_card(id: 3, marker: 'LATEST_CHINESE')]);
    await newRefresh;
    expect(
      service
          .snapshotForAgent('peer')
          .entries
          .any((entry) => entry.promptFragment.contains('LATEST_CHINESE')),
      isTrue,
    );
  });

  test('explicit installed invalidation keeps learned entries', () async {
    final service = _service(
      (_) async => [_card(id: 1, marker: 'INSTALLED_MARKER')],
    );
    final learned = appServices.find<LearnedSkillService>();
    learned.skills.assignAll([
      LearnedSkill(
        id: 'local_only',
        name: 'Local only',
        triggers: const <String>['local only'],
        steps: const <LearnedStep>[],
        summary: 'Stays available.',
      ),
    ]);
    await service.refreshInstalled('self', locale: AppLocale.en);

    final invalidated = service.invalidateInstalled('self');

    expect(
      invalidated.entries.where(
        (entry) => entry.source == PromptSkillSource.marketplace,
      ),
      isEmpty,
    );
    expect(
      invalidated.entries.where(
        (entry) => entry.source == PromptSkillSource.learned,
      ),
      hasLength(1),
    );
  });
}

PromptSkillCatalogService _service(InstalledSkillCardLoader loader) {
  final learned = appServices.isRegistered<LearnedSkillService>()
      ? appServices.find<LearnedSkillService>()
      : appServices.put(LearnedSkillService());
  return appServices.put(
    PromptSkillCatalogService(learnedSkills: learned, loadInstalled: loader),
  );
}

InstalledSkillCard _card({required int id, required String marker}) =>
    InstalledSkillCard(
      agentId: 'self',
      mastery: MasteryBucket.newSkill,
      skill: MarketplaceSkill(
        skillVersionId: id,
        submissionId: id,
        skillKey: 'skill-$id',
        title: 'Skill $id',
        summary: 'Summary $id',
        coverAssetUrl: '',
        publisherId: 'author',
        versionName: '1.0.0',
        permissions: const <String>{},
        category: SkillCategory.reasoning,
        instruction: marker,
        examples: const <String>[],
        manifestDigest: 'digest-$id',
        isFree: true,
      ),
    );
