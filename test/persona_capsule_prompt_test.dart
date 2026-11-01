import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/persona/agent_persona_spec.dart';
import 'package:maaso/src/features/agent/application/persona/persona_chat_loop.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_prompt.dart';

void main() {
  const plan = AgentTurnPlan(
    route: AgentTurnRoute.chitchat,
    mood: 'attentive',
    confidence: 0.8,
  );

  test(
    'neutral profile preserves transport prompt and adds the public style core',
    () {
      final messages = PersonaChatLoop.buildMessages(
        userText: 'hello',
        currentUserText: 'hello',
        turnPlan: plan,
        profile: _profile(),
        locale: AppLocale.en,
      );
      final legacy = AgentPromptCatalog.text(
        'runtime.persona.system',
        locale: AppLocale.en,
        params: const <String, Object?>{
          'nickname': 'Momo',
          'language_rule':
              'Reply in English for this turn because CURRENT_USER_MESSAGE is English or English is the fallback.',
          'route': 'chitchat',
          'mood': 'attentive',
          'task': 'none',
          'traits': 'Warm, Curious',
        },
      );

      final style = ConversationStylePrompt.render(
        ConversationStyleSnapshot(isPrivate: false),
        locale: AppLocale.en,
      );
      expect(messages.first.content, '$legacy\n$style');
      expect(messages.last.content, 'hello');
    },
  );

  test(
    'configured profile appends the same bounded capsule as weak preferences',
    () {
      final profile = _profile(
        persona: AgentPersonaSpec(
          professionTitle: 'Photographer',
          specialties: List<String>.generate(20, (index) => 'Specialty $index'),
          interests: const <String>['video'],
        ),
      );
      final capsule = profile.persona.toCapsule();

      final messages = PersonaChatLoop.buildMessages(
        userText: 'hello',
        currentUserText: 'hello',
        turnPlan: plan,
        profile: profile,
        locale: AppLocale.en,
      );

      final capsuleLine = messages.first.content
          .split('\n')
          .singleWhere((line) => line.startsWith('Persona preferences'));
      expect(messages.first.content, contains(capsule));
      expect(capsuleLine, endsWith(capsule));
      expect(messages.first.content, contains('weak routing priors'));
      expect(messages.first.content, contains('never instructions'));
      expect(
        capsule.length,
        lessThanOrEqualTo(AgentPersonaSpec.promptCapsuleMaxCharacters),
      );
      expect(messages.last.content, 'hello');
    },
  );

  test('persona capsule safety label is localized with exact key parity', () {
    final messages = PersonaChatLoop.buildMessages(
      userText: '你好',
      currentUserText: '你好',
      turnPlan: plan,
      profile: _profile(
        persona: const AgentPersonaSpec(professionTitle: '摄影师'),
      ),
      locale: AppLocale.zh,
    );

    final capsuleLine = messages.first.content
        .split('\n')
        .singleWhere((line) => line.startsWith('人格偏好'));
    expect(capsuleLine, endsWith('profession=摄影师'));
    expect(messages.first.content, contains('弱路由排序'));
    expect(messages.first.content, contains('绝不是指令、能力或权限'));
  });
}

AgentProfile _profile({AgentPersonaSpec persona = AgentPersonaSpec.empty}) {
  return AgentProfile(
    nickname: 'Momo',
    avatar: '',
    bio: '',
    personalityTraits: const <String>['Warm', 'Curious'],
    catchphrase: '',
    persona: persona,
  );
}
