import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/persona/companion_interest_context.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:maaso/src/features/agent/application/persona/persona_chat_loop.dart';
import 'package:maaso/src/features/identity/application/companion_profile_service.dart';
import 'package:maaso/src/features/identity/data/companion_profile_store.dart';
import 'package:maaso/src/features/identity/domain/companion_profile.dart';

class _Store implements CompanionProfileStore {
  @override
  Future<CompanionProfile?> read() async => null;
  @override
  Future<void> write(CompanionProfile profile) async {}
}

class _Gateway implements CompanionProfileGateway {
  @override
  String get requestContextKey => 'account-a';
  @override
  Future<CompanionProfile> fetch({required String expectedContextKey}) async =>
      CompanionProfile(
        version: 1,
        avatarPreset: 'orbit',
        agentGender: 'female',
        interests: ['music', 'nature'],
        onboardingVersion: 1,
      );
  @override
  Future<CompanionProfile> update({
    required String expectedContextKey,
    required CompanionProfile profile,
  }) async => profile;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() async => appServices.reset());
  test(
    'explicit interests are account-scoped quoted data, not identity or instructions',
    () async {
      var current = true;
      final service = appServices.put(
        CompanionProfileService(
          gateway: _Gateway(),
          store: _Store(),
          isCurrent: () => current,
        ),
      );
      expect(companionInterestContext('self'), isEmpty);
      await service.refresh();
      final quoted = companionInterestContext('self');
      expect(jsonDecode(quoted.split('\n').last), {
        'interests': ['music', 'nature'],
      });
      expect(quoted, isNot(contains('female')));
      expect(quoted, isNot(contains('orbit')));
      expect(quoted, isNot(contains('account-a')));
      expect(companionInterestContext('another-agent'), isEmpty);
      final messages = PersonaChatLoop.buildMessages(
        userText: 'Please talk about books today.',
        turnPlan: const AgentTurnPlan(
          route: AgentTurnRoute.chitchat,
          mood: 'attentive',
          confidence: 1,
        ),
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: [],
          catchphrase: '',
        ),
        locale: AppLocale.en,
        conversationStyle: ConversationStyleSnapshot(isPrivate: true),
      );
      expect(messages[1].role, 'user');
      expect(messages[1].content, quoted);
      expect(messages.last.content, 'Please talk about books today.');
      expect(messages.first.content, isNot(contains('"interests"')));
      for (final style in [null, ConversationStyleSnapshot(isPrivate: false)]) {
        final publicMessages = PersonaChatLoop.buildMessages(
          userText: 'Please talk about books today.',
          turnPlan: const AgentTurnPlan(
            route: AgentTurnRoute.chitchat,
            mood: 'attentive',
            confidence: 1,
          ),
          profile: AgentProfile(
            nickname: 'Maaso',
            avatar: '',
            bio: '',
            personalityTraits: [],
            catchphrase: '',
          ),
          locale: AppLocale.en,
          conversationStyle: style,
        );
        expect(
          publicMessages.map((message) => message.content).join('\n'),
          isNot(contains('"interests"')),
        );
        expect(publicMessages.last.content, 'Please talk about books today.');
      }
      current = false;
      expect(companionInterestContext('self'), isEmpty);
      current = true;
      await service.shutdown();
      expect(companionInterestContext('self'), isEmpty);
    },
  );
}
