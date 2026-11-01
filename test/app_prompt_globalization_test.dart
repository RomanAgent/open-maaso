import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/milestone.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/prompts/bundles/app_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/app_prompts_zh.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/delayed_choice_executor.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/working_memory.dart';
import 'package:maaso/src/core/services/world_kb_service.dart';

void main() {
  tearDown(appServices.reset);

  test('app prompt bundles have exact English and Chinese key parity', () {
    expect(appPromptsEn.keys.toSet(), appPromptsZh.keys.toSet());
    expect(appPromptsEn.values, everyElement(isNotEmpty));
    expect(appPromptsZh.values, everyElement(isNotEmpty));
    final placeholder = RegExp(r'@[A-Za-z][A-Za-z0-9_]*');
    for (final key in appPromptsEn.keys) {
      expect(
        placeholder
            .allMatches(appPromptsEn[key]!)
            .map((match) => match.group(0))
            .toSet(),
        placeholder
            .allMatches(appPromptsZh[key]!)
            .map((match) => match.group(0))
            .toSet(),
        reason: 'placeholder parity for $key',
      );
    }
  });

  test(
    'working and short-term memory localize labels but preserve content',
    () {
      final working = WorkingMemory()
        ..currentUserInput = '原文 OriginalCase'
        ..latestEnvCueType = 'custom_sensor';
      final turn = ChatTurn(role: 'user', content: '原文 OriginalCase');

      final english = working.toContextBlock(locale: AppLocale.en);
      final chinese = working.toContextBlock(locale: AppLocale.zh);

      expect(english, contains('[Working Memory]'));
      expect(english, contains('User input: 原文 OriginalCase'));
      expect(chinese, contains('【工作记忆】'));
      expect(chinese, contains('用户输入：原文 OriginalCase'));
      expect(
        turn.toPromptString(locale: AppLocale.en),
        'USER: 原文 OriginalCase',
      );
      expect(turn.toPromptString(locale: AppLocale.zh), '用户: 原文 OriginalCase');
    },
  );

  test('presence handoff localizes instructions but preserves its seed', () {
    final handoff = PresenceProactiveHandoff(
      textSeed: 'shared memory 原文',
      reason: 'quiet_daydream',
      mode: 'daydreaming',
      mood: 'curious',
      attention: 'self',
      arousal: 0.18,
      cooldownKey: 'daydreaming:curious',
      innerThoughtSummary: 'summary 原文',
      createdAt: DateTime(2026, 8, 7, 9, 5),
    );

    final english = handoff.promptFor(locale: AppLocale.en);
    final chinese = handoff.promptFor(locale: AppLocale.zh);

    expect(english, contains('Presence cue at 09:05'));
    expect(english, contains('shared memory 原文'));
    expect(chinese, contains('09:05 的在场感提示'));
    expect(chinese, contains('shared memory 原文'));
    expect(chinese, isNot(contains('If speaking fits')));
  });

  test(
    'relationship prompt localizes effective stage without legacy wall content',
    () {
      final relationship = RelationshipService();
      relationship.state.value = RelationshipState(
        firstMetAt: DateTime(2026, 8, 1),
        stage: RelationshipStage.friend,
        currentStreak: 3,
      );
      relationship.milestones.add(
        Milestone(
          when: DateTime(2026, 8, 6),
          type: 'shared_win',
          title: '作者标题 Original title',
          note: '用户备注 Original note',
        ),
      );

      final english = relationship.summaryForPrompt(locale: AppLocale.en);
      final chinese = relationship.summaryForPrompt(locale: AppLocale.zh);

      expect(english, contains('Our story'));
      expect(english, contains('Relationship: just met'));
      expect(chinese, contains('【我们的故事'));
      expect(chinese, contains('关系：初识'));
      expect(english, isNot(contains('作者标题 Original title')));
      expect(chinese, isNot(contains('作者标题 Original title')));
      expect(chinese, isNot(contains('用户备注 Original note')));
      expect(
        relationship.promptSignature(locale: AppLocale.en),
        contains('rel:en:'),
      );
      expect(
        relationship.promptSignature(locale: AppLocale.zh),
        contains('rel:zh:'),
      );
    },
  );

  test(
    'semantic memory prompt localizes without rewriting stored markdown',
    () {
      final soul = appServices.put(SoulService())
        ..name.value = 'Hiyori 原文'
        ..age.value = 18
        ..gender.value = 'female'
        ..notes.value = '作者记忆 Original soul note';
      final master = appServices.put(MasterProfileService())
        ..name.value = '用户 Original user'
        ..pronouns.value = 'they/them'
        ..notes.value = '用户事实 Original fact';
      appServices.put(WorldKBService()).notes.value = '世界规则 Original rule';
      final memory = MemoryBus();
      final storedMarkdown = soul.toMarkdown();

      final english = memory.l3Block(locale: AppLocale.en);
      final chinese = memory.l3Block(locale: AppLocale.zh);

      expect(storedMarkdown, contains('# Agent Soul'));
      expect(storedMarkdown, contains('- name: Hiyori 原文'));
      expect(english, contains('# Agent Soul'));
      expect(english, contains('# Master'));
      expect(chinese, contains('# 智能体灵魂'));
      expect(chinese, contains('# 用户档案'));
      expect(english, contains('用户事实 Original fact'));
      expect(chinese, contains('用户事实 Original fact'));
      expect(master.toMarkdown(), contains('# Master'));
    },
  );

  test(
    'delayed choice keeps protocol fields neutral and localizes summaries',
    () {
      final english = DelayedChoicePolicy.classify(
        'device.update',
        <String, dynamic>{'url': 'device://lamp'},
        locale: AppLocale.en,
      );
      final chinese = DelayedChoicePolicy.classify(
        'device.update',
        <String, dynamic>{'url': 'device://lamp'},
        locale: AppLocale.zh,
      );

      expect(english.risk, 'side_effect');
      expect(chinese.risk, 'side_effect');
      expect(english.summary, 'Execute device.update on device://lamp');
      expect(chinese.summary, '使用 device.update 对 device://lamp 执行操作');
    },
  );

  test('catalog renders selfie prompts in either language', () {
    expect(
      AgentPromptCatalog.text(
        'app.selfie.director',
        locale: AppLocale.en,
        params: const <String, Object?>{'ownerDirection': '原文 direction'},
      ),
      allOf(contains('vertical selfie clip'), contains('原文 direction')),
    );
    expect(
      AgentPromptCatalog.text(
        'app.selfie.director',
        locale: AppLocale.zh,
        params: const <String, Object?>{'ownerDirection': '原文 direction'},
      ),
      allOf(contains('竖屏自拍视频'), contains('原文 direction')),
    );
  });
}
