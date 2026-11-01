import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_zh.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

void main() {
  test(
    'runtime prompt resources have exact English and Chinese key parity',
    () {
      expect(runtimePromptsEn.keys.toSet(), runtimePromptsZh.keys.toSet());
      expect(runtimePromptsEn, isNotEmpty);
    },
  );

  test(
    'runtime catalog renders one requested locale and keeps protocol keys',
    () {
      final en = AgentPromptCatalog.text(
        'runtime.env.scheduled.cue',
        locale: AppLocale.en,
        params: {
          'time': '09:05',
          'task_id': 'reminder-42',
          'prompt': 'Original 原文',
        },
      );
      final zh = AgentPromptCatalog.text(
        'runtime.env.scheduled.cue',
        locale: AppLocale.zh,
        params: {
          'time': '09:05',
          'task_id': 'reminder-42',
          'prompt': 'Original 原文',
        },
      );

      expect(en, contains('Scheduled task fired at 09:05'));
      expect(en, isNot(contains('定时任务')));
      expect(zh, contains('定时任务在 09:05 触发'));
      expect(zh, isNot(contains('Scheduled task fired')));
      for (final prompt in [en, zh]) {
        expect(prompt, contains('taskId'));
        expect(prompt, contains('reminder-42'));
        expect(prompt, contains('Original 原文'));
      }

      final contract = AgentPromptCatalog.text(
        'runtime.structured.output_contract',
        locale: AppLocale.zh,
      );
      expect(contract, contains('"reply"'));
      expect(contract, contains('"actions"'));
      expect(contract, contains('"type":"skill.call"'));
    },
  );

  test('prompt scope trimming is keyed by stable section ids', () {
    final source = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();
    final start = source.indexOf('String _trimPromptForScope(');
    final end = source.indexOf('String _compactWidgetGuide', start);
    final method = source.substring(start, end);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    expect(method, contains('_PromptSectionId.surface'));
    expect(method, contains('_PromptSectionId.environment'));
    expect(method, isNot(contains('indexOf(')));
    expect(method, isNot(contains('Freeform Surfaces')));
  });

  test(
    'runtime prompt emitters do not keep fixed warmup or presence prose',
    () {
      final runtime = File(
        'lib/src/features/agent/application/agent_runtime.dart',
      ).readAsStringSync();
      final localBackend = File(
        'lib/src/features/agent/application/llamadart_llm_backend.dart',
      ).readAsStringSync();

      expect(runtime, contains('app.presence.context.behavior_active'));
      expect(
        runtime,
        contains('conversationPromptContext(locale: turnContext.locale)'),
      );
      expect(runtime, contains('fullContextBlock('));
      expect(runtime, contains('locale: turnContext.locale'));
      expect(runtime, contains('ConversationStylePrompt.render('));
      expect(runtime, isNot(contains('summaryForPrompt(')));
      expect(runtime, contains('runtime.conversation.delivery_style'));
      expect(runtime, contains('locale: locale'));
      expect(runtime, contains('manifestForPrompt('));
      expect(runtime, contains('app.memory.soul.header'));
      expect(runtime, contains('master.toPromptDataBlock()'));
      // The localized world.md memory preamble has its own runtime key. This
      // is independent of the retired public map/world presentation feature.
      expect(runtime, contains('runtime.soul.world_header'));
      expect(runtime, contains('w.toPromptDataBlock()'));
      expect(
        runtimePromptsEn['runtime.soul.world_header'],
        contains('world.md'),
      );
      expect(
        runtimePromptsZh['runtime.soul.world_header'],
        contains('world.md'),
      );
      expect(runtime, isNot(contains('You may ask one concise follow-up')));
      expect(runtime, isNot(contains("notes.add('Birthday/fact:")));
      expect(runtime, isNot(contains("notes.add('Health/allergy:")));
      expect(runtime, isNot(contains("notes.add('Preference:")));
      expect(localBackend, contains('runtime.local_warmup.chat_user'));
      expect(localBackend, contains('runtime.local_warmup.filler_user'));
      expect(localBackend, contains('runtime.local_warmup.benchmark_user'));
      expect(localBackend, isNot(contains("text: 'hi'")));
      expect(localBackend, isNot(contains('Count from one to twenty.')));
      expect(localBackend, isNot(contains('Can you help me plan this?')));
    },
  );
}
