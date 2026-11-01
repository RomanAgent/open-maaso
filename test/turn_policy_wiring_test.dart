import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final runtime = File(
    'lib/src/features/agent/application/agent_runtime.dart',
  ).readAsStringSync();
  final runtimePrompts = File(
    'lib/src/core/prompts/bundles/runtime_prompts_en.dart',
  ).readAsStringSync();
  late final promptSources = '$runtime\n$runtimePrompts';

  test('chat() owns the router gateway and resolves once per turn', () {
    expect(runtime, contains('TurnPolicyEngine(agentId: agentId)'));
    expect(runtime, contains('TurnRouterGateway('));
    expect(runtime, contains('_turnRouter.resolve('));
  });

  test(
    'live turns require the streaming persona path and explicit PCM sink',
    () {
      expect(runtime, contains('TurnOrigin.live'));
      expect(runtime, contains('liveAudioSink'));
      expect(runtime, contains('live_streaming_tts_unavailable'));
      expect(
        runtime,
        contains('requireSpeechSession: origin == TurnOrigin.live'),
      );
    },
  );

  test('chat() uses the structured action path for cloud turns', () {
    expect(runtime, contains('structuredActionProcess('));
    expect(runtime, contains("details: 'structured_actions'"));
    expect(runtime, contains('policy: policy'));
    expect(runtime, isNot(contains('result = await _brain.iterativeProcess(')));
    expect(
      runtime,
      isNot(contains('result = await _brain.nativeToolProcess(')),
    );
    expect(
      runtime,
      isNot(contains('result = await _brain.streamProcessWithSystemPrompt(')),
    );
  });

  test('Home and runtime carry one Applet scope token for the whole turn', () {
    final home = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();

    expect(home, contains('final turnAppletScopeKey ='));
    expect(home, contains('expectedAppletScopeKey: turnAppletScopeKey'));
    expect(runtime, contains('expectedAppletScopeKey'));
    expect(runtime, contains('_isAppletScopeStale'));
  });

  test('_PromptProfile consumes the policy for wantsSearch', () {
    expect(runtime, contains('required TurnPolicy policy'));
    expect(runtime, contains('wantsSearch: policy.shouldSearch'));
  });

  test('chat() resolves projector media session before policy', () {
    expect(runtime, contains('ProjectorMediaSession _projectorMedia'));
    expect(runtime, contains('_projectorMedia.resolveUserText('));
    expect(runtime, contains('projectorMedia: projectorMedia'));
    expect(runtime, contains('_projectorMedia.observeAssistantText'));
  });

  test('_PromptProfile consumes policy surface decisions', () {
    expect(runtime, contains('policy.projectorMedia.isProjectorFollowUp'));
    expect(runtime, contains('policy.surface.isSurface'));
    expect(
      runtime,
      contains("executableHostGrant.allowsSkillName('FreeformSurface')"),
    );
    expect(runtime, isNot(contains('policy.surface.requiresPlayableGame')));
    expect(runtime, isNot(contains('policy.surface.requiresCardControl')));
  });

  test(
    'the turn-scoped policy block is prepended to the per-turn preamble',
    () {
      expect(runtime, contains('policy.promptBlock'));
    },
  );

  test('runtime consumes presence context and presence proactive cues', () {
    expect(
      runtime,
      contains(
        "import 'package:maaso/src/core/services/agent_presence_service.dart';",
      ),
    );
    expect(runtime, contains('conversationPromptContext('));
    expect(runtime, contains('locale: turnContext.locale'));
    expect(runtime, contains('presence_spoken_thought'));
    expect(runtime, contains('isPresenceCue'));
    expect(runtime, contains('PresenceProactiveHandoff.fromPayload'));
    expect(runtime, contains('consumeProactiveHandoff(e.payload)'));
    expect(runtime, contains('prompt.trim().isEmpty'));
    expect(runtime, contains('handoff.prompt'));
    expect(runtime, contains('markFollowUpAsked()'));
  });

  test('notification taps are queued and bypass ambient proactive gates', () {
    expect(runtime, contains("e.triggerType == 'notification_opened'"));
    expect(runtime, contains('_pendingNotificationInteractions'));
    expect(runtime, contains('_queueNotificationInteraction('));
    expect(runtime, contains('alreadyClaimed:'));
    expect(runtime, contains('TurnOrigin.notificationInteraction'));
    expect(
      runtime,
      contains(
        'origin == TurnOrigin.notificationInteraction\n'
        '        ? AgentActionScope.notificationInteraction',
      ),
    );
    expect(runtime, contains('actionScope: actionScope'));
    expect(
      runtime,
      contains('!isNotificationInteraction &&\n        lastSame != null'),
    );
    expect(
      runtime,
      contains(
        '!isNotificationInteraction &&\n        appServices.isRegistered',
      ),
    );
  });

  test('main prompt no longer teaches Claw javascript output', () {
    final legacyNamespace = String.fromCharCodes([67, 108, 97, 119, 46]);
    expect(runtime, isNot(contains('Only output ONE')));
    expect(runtime, isNot(contains('javascript code block')));
    expect(runtime, isNot(contains('${legacyNamespace}finish')));
    expect(runtime, isNot(contains('${legacyNamespace}tts_speak')));
    expect(promptSources, contains('"actions"'));
    expect(promptSources, contains('surface.show'));
  });

  test('main prompt teaches controlled playfulness and avatar actions', () {
    expect(promptSources, contains('Controlled Playfulness'));
    expect(promptSources, contains('notice specific contrasts'));
    expect(
      promptSources,
      contains('neither the activity nor familiarity implies permission'),
    );
    expect(promptSources, contains('serious or vulnerable'));
    expect(promptSources, contains('avatar.act'));
    final gestureSchemas = RegExp(r'"gesture":"([^"]+)"')
        .allMatches(promptSources)
        .map((match) => match.group(1)!.split('|').toSet());
    expect(
      gestureSchemas.any(
        (values) =>
            values.containsAll({'think', 'explain', 'wave', 'shy', 'listen'}),
      ),
      isTrue,
      reason: 'Keep the existing semantic gestures when extending the enum.',
    );
    expect(promptSources, contains('avatar.react'));
    expect(promptSources, contains('imported FBX clips'));
    final moodSchemas = RegExp(r'"mood":"([^"]+)"')
        .allMatches(promptSources)
        .map((match) => match.group(1)!.split('|').toSet());
    expect(
      moodSchemas.any(
        (values) => values.containsAll({'thinking', 'playful', 'teasing'}),
      ),
      isTrue,
      reason: 'Mood support must survive additions and enum reordering.',
    );
    expect(promptSources, contains('avatar.motion'));
    expect(promptSources, contains('turn_left|turn_right|turn_back|look_back'));
    expect(promptSources, contains('shy_turn|curious_glance|thoughtful_turn'));
    expect(promptSources, contains('host behavior director'));
    expect(promptSources, contains('scene-aware body language'));
    expect(promptSources, isNot(contains('AvatarMotionLearning')));
    expect(promptSources, isNot(contains('Camera/Video Motion Learning')));
    expect(promptSources, contains('idle_shrug'));
    expect(
      promptSources,
      contains('"clip":"idle|idle_shrug|imported_fbx_action_id"'),
    );
    expect(promptSources, contains('imported Unity FBX action ids'));
    expect(promptSources, contains('"sequence"'));
  });

  test('turn-scoped prompt hints do not reintroduce Claw calls', () {
    for (final f in [
      'lib/src/features/home/application/home_controller.dart',
      'lib/src/features/agent/application/projector_media_session.dart',
      'lib/src/features/agent/application/surface/surface_manifest.dart',
    ]) {
      final src = File(f).readAsStringSync();
      final legacyNamespace = String.fromCharCodes([67, 108, 97, 119, 46]);
      expect(src, isNot(contains(legacyNamespace)), reason: f);
      expect(src, isNot(contains('tts_speak')), reason: f);
    }
  });

  test('acknowledgement is pushed through onThinking, localized', () {
    expect(runtime, contains('policy.acknowledgement'));
    expect(runtime, contains('_thinking.add('));

    for (final f in [
      'lib/src/core/localization/en_us.dart',
      'lib/src/core/localization/zh_cn.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(
        src,
        contains('policy.ack_search'),
        reason: '$f missing ack_search',
      );
      expect(src, contains('policy.ack_card'), reason: '$f missing ack_card');
      expect(
        src,
        contains('policy.ack_offline'),
        reason: '$f missing ack_offline',
      );
    }
  });
}
