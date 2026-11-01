import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/security/action_schema_validator.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/production_agent_action_definitions.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_emotion_timeline.dart';
import 'package:maaso/src/features/agent/application/avatar/emotion_to_avatar.dart';
import 'package:maaso/src/features/agent/application/avatar/self_avatar_projection_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/body/avatar_body_intent_policy.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_body_cue_adapter.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_reply_coordinator.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/data/skills/face_skill.dart';
import 'package:maaso/src/features/agent/application/brain_router.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(appServices.reset);

  test(
    'routing hints never turn isolated user words into a forced smile',
    () async {
      appServices.put(LocalBrainService());
      final events = <EmotionStateEvent>[];
      final sub = EventBus().on<EmotionStateEvent>().listen(events.add);
      addTearDown(sub.cancel);
      final router = BrainRouter(agentId: 'smile-test');
      for (final text in [
        'hello',
        '你好',
        'haha',
        '我不开心',
        'How does this work?',
        '今天好累',
        'Thank you',
        '谢谢',
        'I lost someone I love',
      ]) {
        await router.route(text);
      }
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(9));
      for (final event in events) {
        final face = emotionToAvatarParams(
          event.params,
          semanticLabel: event.semanticLabel,
        );
        expect(face.mouthSmile, 0);
        expect(face.happy, 0);
        expect(event.persistent, isFalse);
      }
    },
  );

  test('local model intensity scales actual facial deltas exactly once', () {
    for (final intensity in [0.0, 0.25, 0.55, 1.0]) {
      final face = emotionToAvatarParams(
        emotionParamsForLabel('happy', intensity: intensity),
        semanticLabel: 'happy',
      );
      expect(face.happy, closeTo(intensity, 1e-9));
      expect(face.mouthSmile, closeTo(intensity, 1e-9));
      expect(face.love, 0);
    }
    expect(emotionToAvatarParams(emotionParamsForLabel('neutral')).happy, 0);
  });

  test(
    'quiet support retains concern and attentive eyes without amusement',
    () {
      final calm = emotionToAvatarParams(
        EmotionParams.calm,
        semanticLabel: 'calm',
      );
      final comfort = emotionToAvatarParams(
        EmotionParams.comforting,
        semanticLabel: 'comforting',
      );
      expect(calm.happy, 0);
      expect(comfort.happy, 0);
      expect(comfort.mouthSmile, 0);
      expect(comfort.browConcern, greaterThan(calm.browConcern));
      expect(comfort.eyeOpen, lessThan(1));
    },
  );

  test('articulation and blush cannot imply surprise or a second smile', () {
    final speaking = emotionToAvatarParams(
      EmotionParams.happy.scaled(0.4).copyWith(mouthOpen: 0.9),
      semanticLabel: 'happy',
    );
    expect(speaking.surprised, 0);
    expect(speaking.love, 0);
    expect(speaking.happy, closeTo(0.4, 1e-9));
    final affection = emotionToAvatarParams(
      EmotionParams.love.scaled(0.4),
      semanticLabel: 'love',
    );
    expect(affection.love, closeTo(0.28, 1e-9));
    final surprise = emotionToAvatarParams(
      EmotionParams.surprised.scaled(0.4),
      semanticLabel: 'surprised',
    );
    expect(surprise.surprised, closeTo(0.4, 1e-9));
    final excitement = emotionToAvatarParams(
      EmotionParams.excited,
      semanticLabel: 'excited',
    );
    expect(excitement.surprised, 0);
  });

  testWidgets('one smile releases while its positive mood remains', (
    tester,
  ) async {
    var restored = 0;
    final timeline = AvatarEmotionTimeline(onRestored: () => restored++);
    timeline.set(EmotionParams.happy.scaled(0.4), semanticLabel: 'happy');
    expect(timeline.value.mouthCurve, 0.4);
    await tester.pump(AvatarEmotionTimeline.defaultSmileDuration);
    expect(timeline.label, 'happy');
    expect(timeline.value.mouthCurve, 0);
    expect(timeline.value.eyeShape, 0);
    expect(restored, 1);
    timeline.close();
  });

  testWidgets('repeated smile cues neither extend nor restart the same beat', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 10, 18);
    var restored = 0;
    final timeline = AvatarEmotionTimeline(
      onRestored: () => restored++,
      now: () => now,
    );
    timeline.set(
      EmotionParams.happy.scaled(0.4),
      semanticLabel: 'happy',
      automatic: true,
    );
    await tester.pump(const Duration(milliseconds: 1500));
    now = now.add(const Duration(milliseconds: 1500));
    timeline.set(
      EmotionParams.happy.scaled(0.55),
      semanticLabel: 'happy',
      automatic: true,
    );
    expect(timeline.value.mouthCurve, 0.4);
    await tester.pump(const Duration(milliseconds: 500));
    now = now.add(const Duration(milliseconds: 500));
    expect(restored, 1);
    expect(timeline.value.mouthCurve, 0);
    timeline.set(EmotionParams.happy, semanticLabel: 'happy', automatic: true);
    expect(timeline.value.mouthCurve, 0);
    now = now.add(const Duration(seconds: 3));
    timeline.set(
      EmotionParams.happy.scaled(0.45),
      semanticLabel: 'happy',
      automatic: true,
    );
    expect(timeline.value.mouthCurve, 0.45);
    timeline.close();
  });

  testWidgets(
    'a new authored short smile at three seconds bypasses only the automatic rearm',
    (tester) async {
      var now = DateTime.utc(2026, 10, 18);
      final timeline = AvatarEmotionTimeline(onRestored: () {}, now: () => now);
      timeline.set(
        EmotionParams.happy.scaled(0.3),
        semanticLabel: 'happy',
        duration: const Duration(milliseconds: 1800),
        automatic: true,
      );
      await tester.pump(const Duration(seconds: 3));
      now = now.add(const Duration(seconds: 3));
      expect(timeline.value.mouthCurve, 0);
      timeline.set(
        EmotionParams.happy.scaled(0.4),
        semanticLabel: 'happy',
        duration: const Duration(milliseconds: 1800),
        automatic: true,
      );
      expect(timeline.value.mouthCurve, 0);
      timeline.set(
        EmotionParams.happy.scaled(0.5),
        semanticLabel: 'happy',
        duration: const Duration(milliseconds: 1800),
      );
      expect(timeline.value.mouthCurve, 0.5);
      expect(timeline.hasTransient, isTrue);
      await tester.pump(const Duration(milliseconds: 1800));
      expect(timeline.value.mouthCurve, 0);
      expect(timeline.hasTransient, isFalse);
      timeline.close();
    },
  );

  test(
    'automatic source comes from the host ambient flag, never a JSON field',
    () async {
      final events = <AvatarEmotionIntent>[];
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => null,
        emitEmotion: events.add,
      );
      for (final automatic in [true, false]) {
        await director.applyAct(
          AvatarAct.fromJson({
            'mood': 'happy',
            'gesture': 'none',
            'intensity': 0.35,
          }),
          ambient: automatic,
        );
        await director.applyReaction(
          AvatarReaction.fromJson({
            'mood': 'happy',
            'gesture': 'none',
            'intensity': 0.35,
          }),
          ambient: automatic,
        );
      }
      expect(events.map((event) => event.automatic), [
        true,
        true,
        false,
        false,
      ]);
      expect(
        events.every((event) => !event.persistent && event.duration != null),
        isTrue,
      );
      final catalog = ProductionActionDefinitionCatalog();
      registerProductionAgentActionDefinitions(catalog);
      final schema = catalog.findExact('emotion.set')!.definition.inputSchema;
      expect(
        const ActionSchemaValidator()
            .validate(
              schema: schema,
              value: {'emotion': 'happy', 'automatic': false},
            )
            .isValid,
        isFalse,
      );
    },
  );

  testWidgets(
    'requested held smile survives a transient cue and ends explicitly',
    (tester) async {
      final timeline = AvatarEmotionTimeline(onRestored: () {});
      timeline.set(
        EmotionParams.happy.scaled(0.35),
        semanticLabel: 'happy',
        persistent: true,
      );
      await tester.pump(const Duration(seconds: 10));
      expect(timeline.value.mouthCurve, 0.35);
      timeline.set(
        EmotionParams.thinking,
        semanticLabel: 'thinking',
        duration: const Duration(seconds: 1),
      );
      timeline.cancelTransient();
      expect(timeline.value.mouthCurve, 0.35);
      timeline.set(EmotionParams.serious, semanticLabel: 'serious');
      await tester.pump(const Duration(seconds: 2));
      expect(timeline.value.mouthCurve, lessThanOrEqualTo(0));
      expect(timeline.label, 'serious');
      timeline.close();
    },
  );

  testWidgets(
    'negative context can interrupt a smile immediately without returning it',
    (tester) async {
      final timeline = AvatarEmotionTimeline(onRestored: () {});
      timeline.set(EmotionParams.happy, semanticLabel: 'happy');
      timeline.set(EmotionParams.comforting, semanticLabel: 'comforting');
      expect(timeline.value.browAngle, lessThan(0));
      expect(timeline.value.mouthCurve, 0);
      await tester.pump(const Duration(seconds: 4));
      expect(timeline.value, EmotionParams.comforting);
      timeline.close();
    },
  );

  testWidgets(
    'speech/face projection preserves semantic smile without surprise',
    (tester) async {
      final sink = _Sink();
      final service = SelfAvatarProjectionService(
        accountGeneration: 1,
        mode: () => FeatureRolloutMode.enforce,
        dispatchSink: sink,
      );
      await service.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
        sequence: 1,
      );
      await service.project(
        const SelfAvatarSpeakingProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 2,
          isSpeaking: true,
          generation: 1,
        ),
      );
      await service.project(
        const SelfAvatarLipFrameProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 3,
          amplitude: 0.9,
          generation: 1,
        ),
      );
      await service.project(
        SelfAvatarEmotionProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 4,
          params: EmotionParams.happy.scaled(0.4),
          semanticLabel: 'happy',
        ),
      );
      final expression = sink.events.last.expression!;
      expect(expression.mouthOpen, 0);
      expect(expression.surprised, 0);
      expect(expression.happy, closeTo(0.4, 1e-9));
      expect(sink.events[2].mouthOpen, 0.9);
      await tester.pump(const Duration(seconds: 2));
      await service.waitForIdle();
      expect(sink.events.last.expression!.happy, 0);
      expect(sink.events.last.stopLipSync, isFalse);
      service.onClose();
    },
  );

  test(
    'emotion action supports bounded cue and explicit hold in the same JSON contract',
    () async {
      final catalog = ProductionActionDefinitionCatalog();
      registerProductionAgentActionDefinitions(catalog);
      final definition = catalog.findExact('emotion.set')!.definition;
      final events = <EmotionStateEvent>[];
      final sub = EventBus().on<EmotionStateEvent>().listen(events.add);
      addTearDown(sub.cancel);
      final executor = AgentActionExecutor(
        agentId: 'smile-test',
        locale: AppLocale.en,
        surfaceRuntime: SurfaceRuntime(),
        skillManager: SkillManager(),
        speak: (_) async {},
      );
      for (final action in [
        {
          'type': 'emotion.set',
          'emotion': 'happy',
          'intensity': 0.4,
          'durationMs': 1800,
        },
        {
          'type': 'emotion.set',
          'emotion': 'happy',
          'intensity': 0.35,
          'persistent': true,
        },
      ]) {
        final envelope = AgentActionEnvelope.parse(
          jsonEncode({
            'reply': '',
            'actions': [action],
          }),
        );
        final arguments = Map<String, dynamic>.from(action)..remove('type');
        expect(
          const ActionSchemaValidator()
              .validate(schema: definition.inputSchema, value: arguments)
              .isValid,
          isTrue,
        );
        expect((await executor.execute(envelope)).ok, isTrue);
      }
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      expect(events.first.duration, const Duration(milliseconds: 1800));
      expect(events.first.persistent, isFalse);
      expect(events.first.params.mouthCurve, 0.4);
      expect(events.last.duration, isNull);
      expect(events.last.persistent, isTrue);
      expect(events.last.params.mouthCurve, 0.35);
    },
  );

  test(
    'raw compatibility emotion action scales the facial values once',
    () async {
      final events = <EmotionStateEvent>[];
      final sub = EventBus().on<EmotionStateEvent>().listen(events.add);
      addTearDown(sub.cancel);
      final executor = AgentActionExecutor(
        agentId: 'smile-test',
        locale: AppLocale.en,
        surfaceRuntime: SurfaceRuntime(),
        skillManager: SkillManager(),
        speak: (_) async {},
      );
      for (final params in [
        {'mouthCurve': 0.5, 'eyeShape': 0.2},
        {
          'params': {'mouthCurve': 0.5, 'eyeShape': 0.2},
        },
      ]) {
        final result = await executor.execute(
          AgentActionEnvelope.parse(
            jsonEncode({
              'reply': '',
              'actions': [
                {
                  'type': 'emotion.set',
                  'emotion': 'happy',
                  'intensity': 0.4,
                  'params': params,
                },
              ],
            }),
          ),
        );
        expect(result.ok, isTrue);
      }
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      for (final event in events) {
        expect(event.params.mouthCurve, closeTo(0.2, 1e-9));
        expect(event.params.eyeShape, closeTo(0.08, 1e-9));
      }
    },
  );

  test(
    'fast utterance explicit held face survives high-level admission',
    () async {
      final body = AvatarBodyIntentPolicy.normalize({
        'mood': 'happy',
        'gesture': 'none',
        'gaze': 'none',
        'intensity': 0.35,
        'durationMs': 1200,
        'persistent': true,
      });
      expect(body, containsPair('persistent', true));
      final act = AvatarAct.fromJson(body!);
      expect(act.persistent, isTrue);
      expect(act.durationMs, 1200, reason: 'body protection remains finite');
      final events = <EmotionStateEvent>[];
      final sub = EventBus().on<EmotionStateEvent>().listen(events.add);
      addTearDown(sub.cancel);
      final adapter = ConversationBodyCueAdapter(
        turnId: 'held',
        agentId: 'smile-test',
        isCurrent: () => true,
      );
      final unit = ConversationUtterance(
        turnId: 'held',
        utteranceId: 'held:0',
        sequence: 0,
        draft: ConversationUtteranceDraft(
          text: 'I will hold this smile.',
          body: body,
        ),
      );
      adapter.registerPublished(unit);
      adapter.onTextDelivered(unit);
      await adapter.finish();
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.persistent, isTrue);
      expect(events.single.duration, isNull);
      expect(events.single.params.mouthCurve, 0.35);
    },
  );

  test(
    'ordinary body cues remain temporary and malformed hold fails closed',
    () async {
      final normalized = AvatarBodyIntentPolicy.normalize({
        'mood': 'happy',
        'gesture': 'none',
        'intensity': 0.4,
      });
      expect(AvatarAct.fromJson(normalized!).persistent, isFalse);
      expect(
        AvatarBodyIntentPolicy.normalize({
          'mood': 'happy',
          'persistent': 'true',
        }),
        isNull,
      );
      final events = <AvatarEmotionIntent>[];
      final director = AvatarBehaviorDirector(
        runtimeProvider: () => null,
        emitEmotion: events.add,
      );
      for (final mood in ['happy', 'excited', 'playful']) {
        await director.applyAct(
          AvatarAct.fromJson({
            'mood': mood,
            'gesture': 'none',
            'intensity': 0.4,
          }),
        );
      }
      expect(events, hasLength(3));
      expect(events.every((event) => event.params.mouthCurve > 0), isTrue);
      expect(
        events.every((event) => !event.persistent && event.duration != null),
        isTrue,
      );
    },
  );

  test(
    'FaceControl shares explicit hold semantics without changing call shape',
    () async {
      final events = <EmotionStateEvent>[];
      final sub = EventBus().on<EmotionStateEvent>().listen(events.add);
      addTearDown(sub.cancel);
      final result = FaceSkill(agentId: 'smile-test').methods['setEmotion']!([
        {'emotion': 'happy', 'intensity': 0.3, 'persistent': true},
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(jsonDecode(result as String), {'status': 'success'});
      expect(events.single.persistent, isTrue);
      expect(events.single.duration, isNull);
      expect(events.single.params.mouthCurve, 0.3);
    },
  );

  test(
    'task completion words and displaying a project do not force celebration',
    () {
      final director = AvatarBehaviorDirector(runtimeProvider: () => null);
      for (final line in ['It is ready.', 'Done.', '做好了', '都好了']) {
        for (final actions in [
          <String>{},
          <String>{'surface.show'},
        ]) {
          final plan = director.planAutoReaction(
            AvatarAutoReactionContext(
              reply: line,
              voiceText: line,
              actionTypes: actions,
            ),
          );
          expect(plan.mood, 'calm');
          expect(
            emotionToAvatarParams(EmotionParams.byName[plan.mood]!).mouthSmile,
            0,
          );
        }
      }
      final celebration = director.planAutoReaction(
        const AvatarAutoReactionContext(
          reply: 'Congratulations!',
          voiceText: 'Congratulations!',
          emotionLabel: 'excited',
          actionTypes: {},
        ),
      );
      expect(celebration.mood, 'excited');
    },
  );

  for (final locale in [AppLocale.en, AppLocale.zh]) {
    test(
      'same-turn contextual smile policy is localized for ${locale.name}',
      () {
        final text = AgentPromptCatalog.text(
          'runtime.structured.smile_timing',
          locale: locale,
        );
        expect(text, contains('persistent:true'));
        expect(text, contains('0.25..0.55'));
        expect(text, contains('1200..2500'));
        expect(text, isNot(contains('blendShape')));
        if (locale == AppLocale.en) {
          expect(text, contains('whole exchange'));
          expect(text, contains('explicit request to smile'));
          expect(text, contains('distress'));
          expect(text, contains('no\nextra classification'));
        } else {
          expect(text, contains('整段交流'));
          expect(text, contains('用户明确要求笑'));
          expect(text, contains('痛苦'));
          expect(text, contains('不延迟首字'));
        }
      },
    );
  }
}

class _Sink implements SelfAvatarProjectionDispatchSink {
  final events = <SelfAvatarProjectionDispatch>[];
  @override
  Future<void> dispatch(SelfAvatarProjectionDispatch dispatch) async {
    events.add(dispatch);
  }
}
