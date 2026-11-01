import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/skills/data/installed_skill_locale_refresher.dart';
import 'package:maaso/src/features/skills/data/installed_skill_prompt_provider.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });

  tearDown(appServices.reset);

  test('refreshes installed seed Skill from English to Chinese', () async {
    final registry = await _registry('installed-skill-locale-en-zh.db');
    await registry.upsert(
      agentId: 'self',
      skill: _officialGuideEnglish,
      mastery: MasteryBucket.expert,
    );
    await registry.upsert(agentId: 'self', skill: _authorSkill);

    final result = await InstalledSkillLocaleRefresher(
      registry: registry,
      loadSkill: (id) async =>
          id == '42' ? _officialGuideChinese : _authorSkill,
    ).refreshForAgent('self', expectedLocale: AppLocale.zh);

    expect(result.hasFailures, isFalse);
    expect(result.refreshedCount, 2);
    final cards = await registry.installedForAgent('self');
    final seed = cards.singleWhere(
      (card) => card.skill.skillKey == 'official-guide',
    );
    final author = cards.singleWhere(
      (card) => card.skill.skillKey == 'author-original',
    );
    expect(seed.skill.title, '官方指南');
    expect(seed.skill.contentLocale, 'zh');
    expect(seed.skill.instruction, contains('观察至少两个'));
    expect(seed.mastery, MasteryBucket.expert);
    expect(author.skill.title, '作者 Original Title');
    expect(author.skill.instruction, 'Keep 作者-authored text exactly.');

    final prompt = await InstalledSkillPromptProvider(
      registry: registry,
    ).promptForAgent('self', locale: AppLocale.zh);
    expect(prompt, contains('已安装的社区技能'));
    expect(prompt, contains('观察至少两个'));
    expect(prompt, isNot(contains('inspect at least two')));
    expect(prompt, contains('Keep 作者-authored text exactly.'));
  });

  test('refreshes installed seed Skill from Chinese to English', () async {
    final registry = await _registry('installed-skill-locale-zh-en.db');
    await registry.upsert(
      agentId: 'self',
      skill: _officialGuideChinese,
      mastery: MasteryBucket.growing,
    );
    await registry.upsert(agentId: 'self', skill: _authorSkill);

    final result = await InstalledSkillLocaleRefresher(
      registry: registry,
      loadSkill: (id) async =>
          id == '42' ? _officialGuideEnglish : _authorSkill,
    ).refreshForAgent('self', expectedLocale: AppLocale.en);

    expect(result.hasFailures, isFalse);
    expect(result.refreshedCount, 2);
    final cards = await registry.installedForAgent('self');
    final seed = cards.singleWhere(
      (card) => card.skill.skillKey == 'official-guide',
    );
    final author = cards.singleWhere(
      (card) => card.skill.skillKey == 'author-original',
    );
    expect(seed.skill.title, 'Official Guide');
    expect(seed.skill.contentLocale, 'en');
    expect(seed.skill.instruction, contains('inspect at least two'));
    expect(seed.mastery, MasteryBucket.growing);
    expect(author.skill.title, '作者 Original Title');
    expect(author.skill.instruction, 'Keep 作者-authored text exactly.');

    final prompt = await InstalledSkillPromptProvider(
      registry: registry,
    ).promptForAgent('self', locale: AppLocale.en);
    expect(prompt, contains('Installed Community Skills'));
    expect(prompt, contains('inspect at least two'));
    expect(prompt, isNot(contains('观察至少两个')));
    expect(prompt, contains('Keep 作者-authored text exactly.'));
  });

  test(
    'keeps cached card when localized response identity is invalid',
    () async {
      final registry = await _registry('installed-skill-locale-identity.db');
      await registry.upsert(agentId: 'self', skill: _officialGuideEnglish);

      final result = await InstalledSkillLocaleRefresher(
        registry: registry,
        loadSkill: (_) async => _authorSkill,
      ).refreshForAgent('self', expectedLocale: AppLocale.en);

      expect(result.hasFailures, isTrue);
      expect(result.refreshedCount, 0);
      final cards = await registry.installedForAgent('self');
      expect(cards.single.skill.title, 'Official Guide');
    },
  );

  test(
    'offline locale switch omits stale official text but keeps author text',
    () async {
      final registry = await _registry('installed-skill-locale-offline.db');
      await registry.upsert(agentId: 'self', skill: _officialGuideChinese);
      await registry.upsert(agentId: 'self', skill: _plainEnglishAuthorSkill);

      final result = await InstalledSkillLocaleRefresher(
        registry: registry,
        loadSkill: (_) async => throw StateError('offline'),
      ).refreshForAgent('self', expectedLocale: AppLocale.en);

      expect(result.hasFailures, isTrue);
      final prompt = await InstalledSkillPromptProvider(
        registry: registry,
      ).promptForAgent('self', locale: AppLocale.en);
      expect(prompt, contains('Installed Community Skills'));
      expect(prompt, contains('Keep this author-authored instruction.'));
      expect(prompt, isNot(contains('官方指南')));
      expect(prompt, isNot(contains('观察至少两个')));
      expect(RegExp(r'[\u3400-\u9fff]').hasMatch(prompt), isFalse);
    },
  );

  test('legacy official cache without a locale fails closed', () async {
    final registry = await _registry('installed-skill-locale-legacy.db');
    await registry.upsert(
      agentId: 'self',
      skill: _skill(
        versionId: 42,
        key: 'official-guide',
        title: 'Official Guide',
        summary: 'Observe before acting.',
        instruction: 'Before acting, inspect at least two relevant clues.',
        examples: const ['Name two visible clues.'],
        publisherId: MarketplaceSkill.officialPublisherId,
      ),
    );

    final english = await InstalledSkillPromptProvider(
      registry: registry,
    ).promptForAgent('self', locale: AppLocale.en);
    final chinese = await InstalledSkillPromptProvider(
      registry: registry,
    ).promptForAgent('self', locale: AppLocale.zh);

    expect(english, isEmpty);
    expect(chinese, isEmpty);
  });

  test('latest locale wins an en to zh to en refresh race', () async {
    final registry = await _registry('installed-skill-locale-race.db');
    await registry.upsert(agentId: 'self', skill: _officialGuideEnglish);
    final queue = InstalledSkillLocaleRefreshQueue();
    final zhStarted = Completer<void>();
    final zhResponse = Completer<MarketplaceSkill>();
    final zhImmediate = Completer<String>();
    final enImmediate = Completer<String>();
    late InstalledSkillLocaleRefreshResult zhResult;

    final zhRefresh = queue.run(
      beforeWait: (_) async {
        zhImmediate.complete(
          await InstalledSkillPromptProvider(
            registry: registry,
          ).promptForAgent('self', locale: AppLocale.zh),
        );
      },
      operation: (isCurrent) async {
        zhResult =
            await InstalledSkillLocaleRefresher(
              registry: registry,
              loadSkill: (_) {
                if (!zhStarted.isCompleted) zhStarted.complete();
                return zhResponse.future;
              },
            ).refreshForAgent(
              'self',
              expectedLocale: AppLocale.zh,
              shouldApply: isCurrent,
            );
      },
    );
    await zhStarted.future;
    expect(await zhImmediate.future, isEmpty);

    final enRefresh = queue.run(
      beforeWait: (_) async {
        enImmediate.complete(
          await InstalledSkillPromptProvider(
            registry: registry,
          ).promptForAgent('self', locale: AppLocale.en),
        );
      },
      operation: (isCurrent) async {
        await InstalledSkillLocaleRefresher(
          registry: registry,
          loadSkill: (_) async => _officialGuideEnglish,
        ).refreshForAgent(
          'self',
          expectedLocale: AppLocale.en,
          shouldApply: isCurrent,
        );
      },
    );
    expect(await enImmediate.future, contains('inspect at least two'));
    zhResponse.complete(_officialGuideChinese);
    await Future.wait<void>([zhRefresh, enRefresh]);

    expect(zhResult.superseded, isTrue);
    final seed = (await registry.installedForAgent('self')).single;
    expect(seed.skill.title, 'Official Guide');
    expect(seed.skill.contentLocale, 'en');
    final prompt = await InstalledSkillPromptProvider(
      registry: registry,
    ).promptForAgent('self', locale: AppLocale.en);
    expect(prompt, contains('inspect at least two'));
    expect(prompt, isNot(contains('观察至少两个')));
  });
}

Future<InstalledSkillRegistry> _registry(String path) async {
  final db = appServices.put(DBService());
  await db.init(factory: databaseFactoryMemory, path: path);
  return InstalledSkillRegistry(database: db);
}

MarketplaceSkill _skill({
  required int versionId,
  required String key,
  required String title,
  required String summary,
  required String instruction,
  required List<String> examples,
  required String publisherId,
  String contentLocale = '',
}) => MarketplaceSkill.fromJson({
  'skillVersionId': versionId,
  'submissionId': versionId + 100,
  'skillKey': key,
  'title': title,
  'summary': summary,
  'publisherId': publisherId,
  'versionName': '1.0.0',
  'category': 'observation',
  'instruction': instruction,
  'examples': examples,
  'permissions': <String>[],
  'manifestDigest': List<String>.filled(64, 'a').join(),
  'isFree': true,
  if (contentLocale.isNotEmpty) 'locale': contentLocale,
});

final _officialGuideEnglish = _skill(
  versionId: 42,
  key: 'official-guide',
  title: 'Official Guide',
  summary: 'Observe before acting.',
  instruction: 'Before acting, inspect at least two relevant clues.',
  examples: const ['Name two visible clues.'],
  publisherId: '00000000-0000-4000-8000-000000000001',
  contentLocale: 'en',
);

final _officialGuideChinese = _skill(
  versionId: 42,
  key: 'official-guide',
  title: '官方指南',
  summary: '行动前先观察。',
  instruction: '行动前，观察至少两个相关线索。',
  examples: const ['说出两个可见线索。'],
  publisherId: '00000000-0000-4000-8000-000000000001',
  contentLocale: 'zh',
);

final _authorSkill = _skill(
  versionId: 77,
  key: 'author-original',
  title: '作者 Original Title',
  summary: '作者 keeps this mixed-language source by choice.',
  instruction: 'Keep 作者-authored text exactly.',
  examples: const ['Original 作者 example.'],
  publisherId: 'author-77',
);

final _plainEnglishAuthorSkill = _skill(
  versionId: 78,
  key: 'author-plain-english',
  title: 'Author Original',
  summary: 'The author owns this text.',
  instruction: 'Keep this author-authored instruction.',
  examples: const ['Original author example.'],
  publisherId: 'author-78',
);
