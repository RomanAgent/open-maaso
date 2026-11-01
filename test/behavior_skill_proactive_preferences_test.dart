import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';
import 'package:maaso/src/core/prompts/agent_skill_prompt_metadata.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_skill_descriptor_factory.dart';
import 'package:maaso/src/features/agent/application/skills/behavior_skill.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test(
    'catalog routes explicit do-not-disturb language to the durable method',
    () {
      final spec = SkillCatalog.all.singleWhere(
        (entry) => entry.id == 'behavior',
      );
      final manifest = spec.hostRouting!;
      final skill = spec.factory!('agent-a');

      expect(manifest.methods.toSet(), skill.methods.keys.toSet());
      expect(manifest.methods, contains('setProactiveHardMuted'));
      expect(
        manifest.terms,
        containsAll(<String>[
          '别打扰我',
          '恢复主动联系',
          '在我的Agent中恢复主动联系',
          'resume proactive contact in my agent',
        ]),
      );
      expect(
        AgentSkillDescriptorFactory.fromManifest(manifest).terms,
        containsAll(AgentSkillDescriptorFactory.fromSkill(skill).terms),
      );
      expect(
        AgentSkillPromptMetadata.description(skill, locale: AppLocale.zh),
        allOf(
          contains('setProactiveHardMuted'),
          contains('muted=true'),
          contains('绝不能传 muted=false'),
          contains('我的 Agent > Agent 人格 > 主动陪伴'),
        ),
      );
      expect(
        AgentSkillPromptMetadata.description(skill, locale: AppLocale.en),
        allOf(
          contains('setProactiveHardMuted'),
          contains('muted=true'),
          contains('Never pass muted=false'),
          contains('My Agent > Agent Persona > Proactive companionship'),
        ),
      );
      expect(
        enUS['skill.behavior.description'],
        allOf(contains('durably pause'), contains('only the user can resume')),
      );
      expect(
        zhCH['skill.behavior.description'],
        allOf(contains('持久暂停'), contains('只有用户能从我的 Agent 的人格中恢复')),
      );
    },
  );

  test(
    'explicit hard mute returns only after the account write is durable',
    () async {
      final store = _GatedPreferenceStore();
      final preferences = await ProactivePreferenceService(
        store: store,
        accountScopeDigest: 'a' * 64,
        generation: 1,
      ).init();
      appServices.put<ProactivePreferenceService>(preferences);
      final skill = BehaviorSkill(agentId: 'agent-a');
      store.gateNextWrite();

      var completed = false;
      final resultFuture =
          Future<dynamic>.sync(
            () => skill.methods['setProactiveHardMuted']!(<dynamic>[
              jsonEncode(<String, Object?>{'muted': true}),
            ]),
          ).then<String>((value) {
            completed = true;
            return value.toString();
          });

      await store.writeStarted.future;
      expect(completed, isFalse);
      expect(preferences.effectiveSnapshot.hardMuted, isTrue);

      store.releaseWrite();
      expect(jsonDecode(await resultFuture), <String, Object?>{
        'status': 'ok',
        'hardMuted': true,
      });
      expect(store.persisted?['hardMuted'], isTrue);
    },
  );

  test(
    'agent resume is rejected without writing and unavailable mute fails closed',
    () async {
      final store = _GatedPreferenceStore();
      final preferences = await ProactivePreferenceService(
        store: store,
        accountScopeDigest: 'b' * 64,
        generation: 1,
      ).init();
      appServices.put<ProactivePreferenceService>(preferences);
      final handler = BehaviorSkill().methods['setProactiveHardMuted']!;

      await handler(<dynamic>[true]);
      final writesAfterMute = store.writeCount;
      expect(
        await handler(<dynamic>[
          jsonEncode(<String, Object?>{'muted': false}),
        ]),
        '{"error":"resume_requires_user_control"}',
      );
      expect(store.writeCount, writesAfterMute);
      expect(store.persisted?['hardMuted'], isTrue);
      expect(preferences.effectiveSnapshot.hardMuted, isTrue);

      await preferences.deactivateAndDrain();
      expect(
        await handler(<dynamic>[false]),
        '{"error":"resume_requires_user_control"}',
      );
      expect(
        await handler(<dynamic>[true]),
        '{"error":"proactive_preferences_unavailable"}',
      );
    },
  );
}

final class _GatedPreferenceStore implements ProactivePreferenceStore {
  Map<String, Object?>? persisted;
  int writeCount = 0;
  Completer<void>? _writeGate;
  Completer<void> writeStarted = Completer<void>();

  @override
  Future<Map<String, Object?>?> read() async => persisted;

  @override
  Future<void> write(ProactivePreferenceSnapshot snapshot) async {
    writeCount += 1;
    final gate = _writeGate;
    if (gate != null) {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await gate.future;
      _writeGate = null;
    }
    persisted = Map<String, Object?>.from(snapshot.toStorageJson());
  }

  void gateNextWrite() {
    _writeGate = Completer<void>();
    writeStarted = Completer<void>();
  }

  void releaseWrite() => _writeGate?.complete();
}
