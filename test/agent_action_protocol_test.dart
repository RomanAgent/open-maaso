import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/surface/surface_execution_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:sembast/sembast_memory.dart';

Future<DBService> _memoryDatabase() => DBService().init(
  factory: databaseFactoryMemory,
  path: 'action_protocol_${DateTime.now().microsecondsSinceEpoch}.db',
);

void main() {
  setUp(() {
    appServices.put<SurfaceWorkerFirstFrameWaiter>(
      const SurfaceWorkerTestFirstFrameWaiter(),
    );
  });
  tearDown(appServices.reset);

  group('AgentActionEnvelope', () {
    test('parses fenced JSON without accepting script-style output', () {
      final envelope = AgentActionEnvelope.parse('''
```json
{
  "reply": "Game is ready.",
  "actions": [
    {"type": "emotion.set", "emotion": "excited", "intensity": 0.8},
    {"type": "voice.speak", "text": "Game is ready."}
  ]
}
```
''');

      expect(envelope.reply, 'Game is ready.');
      expect(envelope.actions.map((action) => action.type), [
        'emotion.set',
        'voice.speak',
      ]);
    });

    test('rejects old Claw javascript output', () {
      final legacyNamespace = String.fromCharCodes([67, 108, 97, 119, 46]);
      expect(
        () => AgentActionEnvelope.parse('''
```javascript
${legacyNamespace}tts_speak("hi");
${legacyNamespace}finish("hi");
```
'''),
        throwsA(isA<AgentActionProtocolException>()),
      );
    });

    test(
      'notification interaction accepts only reply voice and emotion actions',
      () {
        final allowed = AgentActionEnvelope.parse('''
{"reply":"Welcome back.","actions":[{"type":"emotion.set","emotion":"happy"},{"type":"voice.speak","text":"Welcome back."}]}
''', scope: AgentActionScope.notificationInteraction);
        expect(allowed.scope, AgentActionScope.notificationInteraction);
        expect(allowed.actions.map((action) => action.type), <String>[
          'emotion.set',
          'voice.speak',
        ]);

        for (final type in <String>[
          'skill.call',
          'app.navigate',
          'surface.show',
          'surface.call',
          'world.intent',
          'avatar.motion',
          'avatar.act',
          'avatar.react',
        ]) {
          expect(
            () => AgentActionEnvelope.parse(
              '{"reply":"Safe reply","actions":[{"type":"$type"}]}',
              scope: AgentActionScope.notificationInteraction,
            ),
            throwsA(
              isA<AgentActionProtocolException>()
                  .having(
                    (error) => error.code,
                    'code',
                    'notification_action_not_allowed',
                  )
                  .having((error) => error.params['type'], 'type', type),
            ),
          );
        }
      },
    );

    test(
      'proactive presence accepts only buffered avatar and emotion actions',
      () {
        final allowed = AgentActionEnvelope.parse('''
{"reply":"I noticed the rain.","actions":[{"type":"emotion.set","emotion":"calm"},{"type":"avatar.act","action":"look_outside"},{"type":"avatar.react","reaction":"curious"}]}
''', scope: AgentActionScope.proactivePresence);
        expect(allowed.scope, AgentActionScope.proactivePresence);
        expect(allowed.actions.map((action) => action.type), <String>[
          'emotion.set',
          'avatar.act',
          'avatar.react',
        ]);

        for (final type in <String>[
          'voice.speak',
          'skill.call',
          'app.navigate',
          'surface.show',
          'surface.call',
          'world.intent',
          'avatar.motion',
        ]) {
          expect(
            () => AgentActionEnvelope.parse(
              '{"reply":"Safe reply","actions":[{"type":"$type"}]}',
              scope: AgentActionScope.proactivePresence,
            ),
            throwsA(
              isA<AgentActionProtocolException>()
                  .having(
                    (error) => error.code,
                    'code',
                    'proactive_action_not_allowed',
                  )
                  .having((error) => error.params['type'], 'type', type),
            ),
          );
        }
      },
    );
  });

  group('AgentActionExecutor', () {
    test(
      'notification scope rejects side effects even if parsing is bypassed',
      () async {
        final spoken = <String>[];
        final surface = SurfaceRuntime();
        final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
        final executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          surfaceRuntime: surface,
          skillManager: SkillManager(),
          speak: spoken.add,
          avatarBehaviorDirector: AvatarBehaviorDirector(
            runtimeProvider: () => avatar,
          ),
        );
        const blockedTypes = <String>[
          'skill.call',
          'app.navigate',
          'surface.show',
          'surface.call',
          'world.intent',
          'avatar.motion',
          'avatar.act',
          'avatar.react',
        ];
        final result = await executor.execute(
          AgentActionEnvelope(
            reply: 'Safe reply',
            scope: AgentActionScope.notificationInteraction,
            actions: blockedTypes
                .map(
                  (type) => AgentAction(
                    type: type,
                    data: <String, Object?>{'type': type},
                  ),
                )
                .toList(),
          ),
        );

        expect(result.errors, hasLength(blockedTypes.length));
        for (final type in blockedTypes) {
          expect(
            result.errors,
            contains(
              '$type: Bad state: $type is not allowed in '
              'notificationInteraction scope',
            ),
          );
        }
        expect(surface.isVisible.value, isFalse);
        expect(avatar.primitiveType, isNull);
        expect(avatar.motionType, isNull);
        expect(spoken, <String>['Safe reply']);
      },
    );

    test(
      'structured local surface actions can save beyond five owned Applets',
      () async {
        final database = await _memoryDatabase();
        appServices.put<DBService>(database);
        for (var index = 0; index < 8; index++) {
          await database.saveAgentWidget(
            AgentWidget(
              agentId: 'self',
              title: 'Applet $index',
              kind: 'surface',
              spec: <String, Object?>{
                'surfaceId': 'existing-$index',
                'experienceType': 'utility',
              },
              createdAt: DateTime.utc(2026, 8, 8),
            ),
          );
        }
        final runtime = SurfaceRuntime();
        final authorization = _surfaceAuthorization(
          SurfaceExperienceType.utility,
        );
        final executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.zh,
          surfaceRuntime: runtime,
          skillManager: authorization.manager,
          expectedAppletScopeKey: authorization.scopeKey,
          surfaceExecutionGrant: authorization.grant,
          confirmAppletSave: (_) async => true,
          speak: (_) async {},
        );

        final result = await executor.execute(
          AgentActionEnvelope.parse('''
{
  "reply": "做好啦",
  "actions": [{
    "type": "surface.show",
    "surface": {
      "title": "计分板",
      "experienceType": "utility",
      "kind": "fullscreen",
      "rendering": "workerCanvas",
      "html": "",
      "css": "",
      "js": "Game.define({init(){return {};},update(state){return state;},draw(){return [{type:'clear',color:'#10131a'}];},input(state){return state;}});",
      "manifest": {"events": [], "actions": []}
    }
  }]
}
'''),
        );

        expect(result.errors, isEmpty);
        expect(result.errorCodes, isEmpty);
        expect(runtime.isVisible.value, isTrue);
        expect(await database.getAllWidgets(), hasLength(9));
      },
    );

    test('real cloud quota errors keep their typed protocol mapping', () {
      const result = AgentActionExecutionResult(
        errors: <String>['applet_quota_reached'],
        errorCodes: <AgentActionExecutionErrorCode>[
          AgentActionExecutionErrorCode.appletQuotaReached,
        ],
      );
      expect(
        AgentActionExecutionErrorCode.fromError(
          const AppletQuotaExceededException(limit: 5),
        ),
        AgentActionExecutionErrorCode.appletQuotaReached,
      );
      expect(
        agentActionExecutionPromptKey(result),
        'app.action_protocol.applet_quota_reached',
      );
      expect(
        AgentActionExecutionErrorCode.fromError(
          const AppletQuotaUnavailableException(),
        ),
        AgentActionExecutionErrorCode.appletQuotaUnavailable,
      );
      expect(
        agentActionExecutionPromptKey(
          const AgentActionExecutionResult(errors: <String>['failed']),
        ),
        'app.action_protocol.execution_failed',
      );
    });

    test('rejects empty surface payloads before showing them', () async {
      final runtime = SurfaceRuntime();
      final executor = AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        surfaceRuntime: runtime,
        skillManager: SkillManager(),
        speak: (_) async {},
      );

      final result = await executor.execute(
        AgentActionEnvelope.parse('''
{
  "reply": "I made a board game.",
  "actions": [
    {
      "type": "surface.show",
      "surface": {
        "title": "大富翁 Mini",
        "kind": "fullscreen",
        "rendering": "canvas",
        "html": "<main></main>",
        "css": "body{margin:0}",
        "js": ""
      }
    }
  ]
}
'''),
      );

      expect(result.ok, isFalse);
      expect(result.errors.single, contains('surface.show'));
      expect(
        result.errors.single,
        contains('surface html must contain visible content or a render host'),
      );
      expect(runtime.isVisible.value, isFalse);
      expect(runtime.activeProject.value, isNull);
    });

    test(
      'rejects interactive canvas surfaces without startup script',
      () async {
        final runtime = SurfaceRuntime();
        final executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          surfaceRuntime: runtime,
          skillManager: SkillManager(),
          speak: (_) async {},
        );

        final result = await executor.execute(
          AgentActionEnvelope.parse('''
{
  "reply": "I made a playable canvas.",
  "actions": [
    {
      "type": "surface.show",
      "surface": {
        "title": "大富翁 Mini",
        "kind": "fullscreen",
        "rendering": "canvas",
        "html": "<canvas id=\\"game\\"></canvas>",
        "css": "canvas{width:100%;height:100%}",
        "js": ""
      }
    }
  ]
}
'''),
        );

        expect(result.ok, isFalse);
        expect(
          result.errors.single,
          contains('interactive surface js must not be empty'),
        );
        expect(runtime.isVisible.value, isFalse);
      },
    );

    test('shows generated surfaces through host-owned validation', () async {
      final database = await _memoryDatabase();
      appServices.put<DBService>(database);
      final runtime = SurfaceRuntime();
      final authorization = _surfaceAuthorization(SurfaceExperienceType.game);
      final executor = AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        surfaceRuntime: runtime,
        skillManager: authorization.manager,
        expectedAppletScopeKey: authorization.scopeKey,
        surfaceExecutionGrant: authorization.grant,
        speak: (_) async {},
      );

      final result = await executor.execute(
        AgentActionEnvelope.parse('''
{
  "reply": "I made a playable canvas.",
  "actions": [
    {
      "type": "surface.show",
      "surface": {
        "id": "model-reused-id",
        "title": "Thunder Shooter",
        "summary": "A fast arcade spaceship shooter with dodge controls.",
        "experienceType": "game",
        "kind": "fullscreen",
        "rendering": "workerCanvas",
        "html": "",
        "css": "",
        "js": "Game.define({init({width,height,dpr}){Game.emit('ready',{});return {x:width/2};},update(state,frame){return state;},draw(state,frame){return [{type:'clear',color:'#10131a'}];},input(state,event){return state;}});",
        "manifest": {
          "events": [{"name":"ready","schema":{}}],
          "actions": [{"name":"start","schema":{}}]
        }
      }
    }
  ]
}
'''),
      );

      expect(result.errors, isEmpty);
      expect(runtime.isVisible.value, isTrue);
      expect(runtime.activeProject.value?.title, 'Thunder Shooter');
      expect(runtime.activeProject.value?.kind.name, 'fullscreen');
      expect(runtime.activeProject.value?.rendering.name, 'workerCanvas');
      expect(
        runtime.activeProject.value?.experienceType,
        SurfaceExperienceType.game,
      );
      expect(runtime.activeProject.value?.id, isNotEmpty);
      expect(runtime.activeProject.value?.id, isNot('model-reused-id'));
      final saved = (await database.getAllWidgets()).single;
      expect(
        saved.subtitle,
        'A fast arcade spaceship shooter with dodge controls.',
      );
    });

    test('executes avatar.react through the host behavior director', () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final emotions = <AvatarEmotionIntent>[];
      final executor = AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        surfaceRuntime: SurfaceRuntime(),
        skillManager: SkillManager(),
        speak: (_) async {},
        avatarBehaviorDirector: AvatarBehaviorDirector(
          runtimeProvider: () => runtime,
          emitEmotion: emotions.add,
        ),
      );

      final result = await executor.execute(
        AgentActionEnvelope.parse('''
{
  "reply": "我想想。",
  "actions": [
    {
      "type": "avatar.react",
      "mood": "thinking",
      "gesture": "think",
      "gaze": "down",
      "intensity": 0.7
    }
  ]
}
'''),
      );

      expect(result.errors, isEmpty);
      expect(emotions.single.label, 'thinking');
      expect(runtime.primitiveType, 'think');
      expect(runtime.gaze?.headY, lessThan(0));
    });

    test('executes avatar.act as semantic body language', () async {
      final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      final emotions = <AvatarEmotionIntent>[];
      final executor = AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        surfaceRuntime: SurfaceRuntime(),
        skillManager: SkillManager(),
        speak: (_) async {},
        avatarBehaviorDirector: AvatarBehaviorDirector(
          runtimeProvider: () => runtime,
          emitEmotion: emotions.add,
        ),
      );

      final result = await executor.execute(
        AgentActionEnvelope.parse('''
{
  "reply": "我来解释一下。",
  "actions": [
    {
      "type": "avatar.act",
      "mood": "thinking",
      "gesture": "explain",
      "gaze": "user",
      "style": "subtle",
      "intensity": 0.72,
      "durationMs": 1500
    },
    {"type": "voice.speak", "text": "我来解释一下。"}
  ]
}
'''),
      );

      expect(result.errors, isEmpty);
      expect(emotions.single.label, 'thinking');
      expect(runtime.handIkTarget, isNull);
      expect(runtime.clipId, 'annie_g_offer_r');
      expect(runtime.clipOpts?['durationMs'], 1500);
      expect(runtime.clipOpts?['intensity'], 0.72);
      expect(runtime.primitiveType, isNull);
    });

    test(
      'executes avatar.motion body motions through the active runtime',
      () async {
        final active = appServices.put(ActiveAvatarRuntime());
        final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
        active.register(avatar);
        final executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          surfaceRuntime: SurfaceRuntime(),
          skillManager: SkillManager(),
          speak: (_) async {},
        );

        final result = await executor.execute(
          AgentActionEnvelope.parse('''
{
  "reply": "我转过去看一下。",
  "actions": [
    {
      "type": "avatar.motion",
      "motion": "turn_back",
      "options": {"durationMs": 1400, "intensity": 0.8}
    }
  ]
}
'''),
        );

        expect(result.errors, isEmpty);
        expect(avatar.motionType, 'turn_back');
        expect(avatar.motionOpts?['durationMs'], 1400);
        expect(avatar.motionOpts?['intensity'], 0.8);
        expect(avatar.primitiveType, isNull);
      },
    );

    test(
      'executes avatar.motion sequences through the active runtime',
      () async {
        final active = appServices.put(ActiveAvatarRuntime());
        final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
        active.register(avatar);
        final executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          surfaceRuntime: SurfaceRuntime(),
          skillManager: SkillManager(),
          speak: (_) async {},
        );

        final result = await executor.execute(
          AgentActionEnvelope.parse('''
{
  "reply": "我先偷看一下再回来。",
  "actions": [
    {
      "type": "avatar.motion",
      "sequence": [
        {"motion": "look_back", "options": {"durationMs": 500, "intensity": 0.6}},
        {"motion": "turn_back", "atMs": 450, "options": {"durationMs": 900, "intensity": 0.7}},
        {"motion": "reset", "atMs": 1800, "options": {"durationMs": 700}}
      ]
    }
  ]
}
'''),
        );

        expect(result.errors, isEmpty);
        expect(avatar.motionSequence, hasLength(3));
        expect(avatar.motionSequence?[0].motion, 'look_back');
        expect(avatar.motionSequence?[0].options['durationMs'], 500);
        expect(avatar.motionSequence?[1].motion, 'turn_back');
        expect(avatar.motionSequence?[1].atMs, 450);
        expect(avatar.motionSequence?[2].motion, 'reset');
        expect(avatar.motionType, isNull);
      },
    );

    test('executes avatar.motion clips through the active runtime', () async {
      final active = appServices.put(ActiveAvatarRuntime());
      final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      active.register(avatar);
      final executor = AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        surfaceRuntime: SurfaceRuntime(),
        skillManager: SkillManager(),
        speak: (_) async {},
      );

      final result = await executor.execute(
        AgentActionEnvelope.parse('''
{
  "reply": "我走两步给你看。",
  "actions": [
    {
      "type": "avatar.motion",
      "clip": "walk_two_steps",
      "options": {"fadeMs": 180, "speed": 1.0}
    }
  ]
}
'''),
      );

      expect(result.errors, isEmpty);
      expect(avatar.clipId, 'walk_two_steps');
      expect(avatar.clipOpts?['fadeMs'], 180);
      expect(avatar.clipOpts?['speed'], 1.0);
      expect(avatar.motionType, isNull);
      expect(avatar.primitiveType, isNull);
    });

    test(
      'resolves imported idle clip aliases for the active Unity runtime',
      () async {
        final active = appServices.put(ActiveAvatarRuntime());
        final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
        active.register(avatar);
        final executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          surfaceRuntime: SurfaceRuntime(),
          skillManager: SkillManager(),
          speak: (_) async {},
        );

        final result = await executor.execute(
          AgentActionEnvelope.parse('''
{
  "reply": "拜拜。",
  "actions": [
    {"type": "avatar.motion", "clip": "ldle"}
  ]
}
'''),
        );

        expect(result.errors, isEmpty);
        expect(avatar.clipId, 'idle');
      },
    );

    test(
      'resolves imported idle variant aliases for the active Unity runtime',
      () async {
        final active = appServices.put(ActiveAvatarRuntime());
        final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
        active.register(avatar);
        final executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          surfaceRuntime: SurfaceRuntime(),
          skillManager: SkillManager(),
          speak: (_) async {},
        );

        final result = await executor.execute(
          AgentActionEnvelope.parse('''
{
  "reply": "我换个站姿。",
  "actions": [
    {"type": "avatar.motion", "clip": "shrug_idle"}
  ]
}
'''),
        );

        expect(result.errors, isEmpty);
        expect(avatar.clipId, 'idle_shrug');
        expect(avatar.motionType, isNull);
        expect(avatar.primitiveType, isNull);
      },
    );

    test('plays Unity avatar.motion clips on Unity backend', () async {
      final active = appServices.put(ActiveAvatarRuntime());
      final avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
      active.register(avatar);
      final executor = AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        surfaceRuntime: SurfaceRuntime(),
        skillManager: SkillManager(),
        speak: (_) async {},
      );

      final result = await executor.execute(
        AgentActionEnvelope.parse('''
{
  "reply": "拜拜。",
  "actions": [
    {"type": "avatar.motion", "clip": "wave"}
  ]
}
'''),
      );

      expect(result.errors, isEmpty);
      expect(avatar.clipId, 'annie_wave');
    });

    group('avatar motion facial cues', () {
      late ActiveAvatarRuntime active;
      late _RecordingAvatarRuntime avatar;
      late AgentActionExecutor executor;
      late List<EmotionStateEvent> emotions;
      late List<AvatarEmotionResetEvent> resets;

      setUp(() {
        active = appServices.put(ActiveAvatarRuntime());
        avatar = _RecordingAvatarRuntime(AvatarBackendKind.unity);
        active.register(avatar);
        emotions = [];
        resets = [];
        final emotionSubscription = EventBus().on<EmotionStateEvent>().listen(
          emotions.add,
        );
        final resetSubscription = EventBus()
            .on<AvatarEmotionResetEvent>()
            .listen(resets.add);
        addTearDown(emotionSubscription.cancel);
        addTearDown(resetSubscription.cancel);
        executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          surfaceRuntime: SurfaceRuntime(),
          skillManager: SkillManager(),
          speak: (_) async {},
        );
      });

      Future<AgentActionExecutionResult> executeAvatarActions(
        List<Map<String, Object?>> actions,
      ) async {
        final result = await executor.execute(
          AgentActionEnvelope.parse(
            jsonEncode({'reply': '', 'actions': actions}),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        return result;
      }

      for (final (clip, mood) in [
        ('crying', 'sad'),
        ('happy_345', 'happy'),
        ('shy', 'shy'),
        ('wave', 'calm'),
        ('annie_wave', 'calm'),
        ('annie_think', 'thinking'),
        ('annie_shrug', 'confused'),
      ]) {
        test('$clip adds a bounded $mood cue after body playback', () async {
          final result = await executeAvatarActions([
            {'type': 'avatar.motion', 'clip': clip},
          ]);

          expect(result.ok, isTrue);
          expect(avatar.clipId, clip == 'wave' ? 'annie_wave' : clip);
          expect(avatar.clipOpts, isEmpty);
          expect(emotions, hasLength(1));
          expect(emotions.single.semanticLabel, mood);
          expect(emotions.single.agentId, 'self');
          expect(emotions.single.duration, const Duration(milliseconds: 1200));
          expect(emotions.single.params.intensity, 0.45);
          if (clip == 'wave') {
            expect(emotions.single.params.mouthCurve, 0);
          }
          if (clip == 'crying') {
            expect(emotions.single.params.mouthCurve, lessThan(0));
          }
        });
      }

      test(
        'known primitive and motion commands also carry facial cues',
        () async {
          final result = await executeAvatarActions([
            {'type': 'avatar.motion', 'primitive': 'wave'},
            {'type': 'avatar.motion', 'motion': 'think'},
          ]);

          expect(result.ok, isTrue);
          expect(avatar.primitiveType, 'wave');
          expect(avatar.motionType, 'think');
          expect(emotions.map((event) => event.semanticLabel), [
            'calm',
            'thinking',
          ]);
        },
      );

      test(
        'explicit mood wins and uses the command duration without changing it',
        () async {
          final result = await executeAvatarActions([
            {
              'type': 'avatar.motion',
              'clip': 'crying',
              'mood': 'serious',
              'intensity': 0.3,
              'options': {'durationMs': 850, 'speed': 0.8},
            },
          ]);

          expect(result.ok, isTrue);
          expect(avatar.clipOpts, {'durationMs': 850, 'speed': 0.8});
          expect(emotions.single.semanticLabel, 'serious');
          expect(emotions.single.params.intensity, 0.3);
          expect(emotions.single.duration, const Duration(milliseconds: 850));
        },
      );

      for (final (requested, expected) in [
        (0, 1200),
        (-1, 1200),
        (10, 200),
        (8000, 8000),
        (90000, 30000),
      ]) {
        test(
          'duration $requested is bounded to $expected milliseconds',
          () async {
            final result = await executeAvatarActions([
              {
                'type': 'avatar.motion',
                'clip': 'crying',
                'options': {'durationMs': requested},
              },
            ]);

            expect(result.ok, isTrue);
            expect(emotions.single.duration, Duration(milliseconds: expected));
            expect(avatar.clipOpts?['durationMs'], requested);
          },
        );
      }

      test('a pending body command cannot emit its face early', () async {
        final pending = _PendingClipAvatarRuntime();
        active.register(pending);
        final execution = executeAvatarActions([
          {'type': 'avatar.motion', 'clip': 'crying'},
        ]);
        await pending.started.future;
        await Future<void>.delayed(Duration.zero);
        expect(emotions, isEmpty);

        pending.completion.complete();
        expect((await execution).ok, isTrue);
        expect(emotions.single.semanticLabel, 'sad');
      });

      test('failed body commands cannot emit an expression', () async {
        final pending = _PendingClipAvatarRuntime();
        active.register(pending);
        final execution = executeAvatarActions([
          {'type': 'avatar.motion', 'clip': 'crying'},
        ]);
        await pending.started.future;
        pending.completion.completeError(
          PlatformException(code: 'avatar_authority_owned'),
        );

        final result = await execution;
        expect(result.errors.single, contains('avatar_authority_owned'));
        expect(emotions, isEmpty);
        expect(resets, isEmpty);
      });

      test(
        'emitMood false and mood none keep the body but suppress its face',
        () async {
          final result = await executeAvatarActions([
            {'type': 'avatar.motion', 'clip': 'crying', 'emitMood': false},
            {
              'type': 'avatar.motion',
              'primitive': 'wave',
              'options': {'emitMood': false},
            },
            {'type': 'avatar.motion', 'motion': 'think', 'mood': 'none'},
          ]);

          expect(result.ok, isTrue);
          expect(avatar.clipId, 'crying');
          expect(avatar.primitiveType, 'wave');
          expect(avatar.motionType, 'think');
          expect(emotions, isEmpty);
        },
      );

      test(
        'scoped clips preserve explicit face suppression and override',
        () async {
          final suppressed = await executeAvatarActions([
            {'type': 'avatar.motion', 'clip': 'annie_wave', 'emitMood': false},
            {
              'type': 'avatar.motion',
              'clip': 'annie_think',
              'options': {'emitMood': false},
            },
            {'type': 'avatar.motion', 'clip': 'annie_shrug', 'mood': 'none'},
          ]);
          expect(suppressed.ok, isTrue);
          expect(avatar.clipId, 'annie_shrug');
          expect(emotions, isEmpty);

          final explicit = await executeAvatarActions([
            {
              'type': 'avatar.motion',
              'clip': 'annie_wave',
              'mood': 'serious',
              'options': {'durationMs': 850},
            },
          ]);
          expect(explicit.ok, isTrue);
          expect(emotions.single.semanticLabel, 'serious');
          expect(emotions.single.duration, const Duration(milliseconds: 850));
        },
      );

      test(
        'unknown motions poses sequences and neutral gestures infer no face',
        () async {
          final result = await executeAvatarActions([
            {'type': 'avatar.motion', 'clip': 'annie_unknown_wave'},
            {'type': 'avatar.motion', 'clip': 'custom_dance', 'mood': 'happy'},
            {'type': 'avatar.motion', 'primitive': 'custom_gesture'},
            {'type': 'avatar.motion', 'motion': 'custom_motion'},
            {'type': 'avatar.motion', 'primitive': 'nod'},
            {
              'type': 'avatar.motion',
              'bodyPose': {'headYaw': 0.2},
              'mood': 'sad',
            },
            {
              'type': 'avatar.motion',
              'sequence': [
                {'clip': 'crying'},
                {'motion': 'reset'},
              ],
              'mood': 'sad',
            },
          ]);

          expect(result.ok, isTrue);
          expect(avatar.clipId, 'custom_dance');
          expect(avatar.bodyPose, isNotNull);
          expect(avatar.motionSequence, hasLength(2));
          expect(emotions, isEmpty);
          expect(resets, isEmpty);
        },
      );

      for (final emotionFirst in [true, false]) {
        for (final type in ['avatar.motion', 'avatar.act', 'avatar.react']) {
          test(
            'explicit emotion ${emotionFirst ? 'before' : 'after'} $type wins',
            () async {
              final explicit = <String, Object?>{
                'type': 'emotion.set',
                'emotion': 'serious',
              };
              final body = <String, Object?>{
                'type': type,
                if (type == 'avatar.motion')
                  'clip': 'crying'
                else
                  'gesture': 'wave',
                'mood': 'happy',
              };
              final result = await executeAvatarActions(
                emotionFirst ? [explicit, body] : [body, explicit],
              );

              expect(result.ok, isTrue);
              expect(avatar.clipId ?? avatar.primitiveType, isNotNull);
              expect(emotions, hasLength(1));
              expect(emotions.single.semanticLabel, 'serious');
              expect(emotions.single.duration, isNull);
            },
          );
        }
      }

      test('reset cancels the temporary face through its own event', () async {
        final result = await executeAvatarActions([
          {'type': 'avatar.motion', 'clip': 'crying'},
          {'type': 'avatar.motion', 'motion': 'reset'},
        ]);

        expect(result.ok, isTrue);
        expect(avatar.motionType, 'reset');
        expect(emotions, hasLength(1));
        expect(resets.single.agentId, 'self');
      });

      test(
        'reset honors emitMood false and an explicit batch emotion',
        () async {
          expect(
            (await executeAvatarActions([
              {'type': 'avatar.motion', 'motion': 'reset', 'emitMood': false},
            ])).ok,
            isTrue,
          );
          expect(
            (await executeAvatarActions([
              {'type': 'avatar.motion', 'motion': 'reset'},
              {'type': 'emotion.set', 'emotion': 'serious'},
            ])).ok,
            isTrue,
          );

          expect(avatar.motionType, 'reset');
          expect(resets, isEmpty);
          expect(emotions.single.semanticLabel, 'serious');
        },
      );
    });

    test(
      'auto-fills a natural avatar reaction before spoken fallback',
      () async {
        final runtime = _RecordingAvatarRuntime(AvatarBackendKind.unity);
        final spoken = <String>[];
        final executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          surfaceRuntime: SurfaceRuntime(),
          skillManager: SkillManager(),
          speak: spoken.add,
          avatarBehaviorDirector: AvatarBehaviorDirector(
            runtimeProvider: () => runtime,
          ),
        );

        final result = await executor.execute(
          AgentActionEnvelope.parse('''
{
  "reply": "我先捋一下。",
  "actions": [
    {"type": "emotion.set", "emotion": "thinking", "intensity": 0.6}
  ]
}
'''),
        );

        expect(result.errors, isEmpty);
        expect(runtime.clipId, 'annie_think');
        expect(runtime.primitiveType, isNull);
        expect(spoken, ['我先捋一下。']);
      },
    );

    test(
      'cancelled action sequence cannot fall through to reply speech',
      () async {
        final spoken = <String>[];
        var cancellationChecks = 0;
        final executor = AgentActionExecutor(
          agentId: 'self',
          locale: AppLocale.en,
          surfaceRuntime: SurfaceRuntime(),
          skillManager: SkillManager(),
          speak: spoken.add,
          shouldCancel: () => ++cancellationChecks >= 2,
        );

        final result = await executor.execute(
          AgentActionEnvelope.parse('''
{
  "reply": "这句不应该在取消后补说。",
  "actions": [
    {"type": "emotion.set", "emotion": "thinking", "intensity": 0.6}
  ]
}
'''),
        );

        expect(result.errors, isNotEmpty);
        expect(spoken, isEmpty);
      },
    );

    test('avatar loading does not block automatic reaction speech', () async {
      final runtime = _RecordingAvatarRuntime(
        AvatarBackendKind.unity,
        transientError: PlatformException(
          code: 'not_ready',
          message: 'Unity WebGL is loading',
        ),
      );
      final spoken = <String>[];
      final executor = AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        surfaceRuntime: SurfaceRuntime(),
        skillManager: SkillManager(),
        speak: spoken.add,
        avatarBehaviorDirector: AvatarBehaviorDirector(
          runtimeProvider: () => runtime,
        ),
      );

      final result = await executor.execute(
        AgentActionEnvelope.parse('''
{
  "reply": "我先捋一下。",
  "actions": [
    {"type": "emotion.set", "emotion": "thinking", "intensity": 0.6}
  ]
}
'''),
      );

      expect(result.errors, isEmpty);
      expect(spoken, ['我先捋一下。']);
    });

    test('explicit avatar act reports renderer loading', () async {
      final runtime = _RecordingAvatarRuntime(
        AvatarBackendKind.unity,
        transientError: PlatformException(
          code: 'not_ready',
          message: 'Unity WebGL is loading',
        ),
      );
      final executor = AgentActionExecutor(
        agentId: 'self',
        locale: AppLocale.en,
        surfaceRuntime: SurfaceRuntime(),
        skillManager: SkillManager(),
        speak: (_) async {},
        avatarBehaviorDirector: AvatarBehaviorDirector(
          runtimeProvider: () => runtime,
        ),
      );

      final result = await executor.execute(
        AgentActionEnvelope.parse('''
{
  "reply": "",
  "actions": [
    {"type": "avatar.act", "mood": "thinking", "gesture": "think"}
  ]
}
'''),
      );

      expect(result.errors, hasLength(1));
      expect(result.errors.single, contains('not_ready'));
    });
  });
}

({SkillManager manager, SurfaceExecutionGrant grant, String scopeKey})
_surfaceAuthorization(SurfaceExperienceType experienceType) {
  final registry = LazyHostSkillRegistry(
    agentId: 'self',
    specs: SkillCatalog.all,
    enabledSkillIds: const <String>{'freeform_surface'},
  );
  final descriptor = registry.descriptorFor('FreeformSurface')!;
  final hostGrant = registry.issueGrant(
    TurnSkillGrant.bounded(
      rankedDescriptors: <SkillDescriptor>[descriptor],
      maxSkills: 1,
      promptBudget: 4096,
    ),
  );
  final manager = SkillManager()
    ..registerSkill(hostGrant.activatedSkills.single);
  final scopeKey = AppletLocalOwnership.currentScopeKey();
  return (
    manager: manager,
    scopeKey: scopeKey,
    grant: SurfaceExecutionGrant.issue(
      executableHostGrant: hostGrant,
      agentId: 'self',
      appletScopeKey: scopeKey,
      experienceType: experienceType,
    ),
  );
}

class _PendingClipAvatarRuntime extends _RecordingAvatarRuntime {
  _PendingClipAvatarRuntime() : super(AvatarBackendKind.unity);

  final started = Completer<void>();
  final completion = Completer<void>();

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async {
    started.complete();
    await completion.future;
    await super.playAnimationClip(id, opts);
  }
}

class _RecordingAvatarRuntime extends AvatarRuntime {
  _RecordingAvatarRuntime(this.backendKind, {this.transientError});

  @override
  final AvatarBackendKind backendKind;
  final PlatformException? transientError;

  @override
  final isReady = false.obs;

  String? primitiveType;
  Map<String, dynamic>? primitiveOpts;
  String? motionType;
  Map<String, dynamic>? motionOpts;
  String? clipId;
  Map<String, dynamic>? clipOpts;
  List<AvatarMotionStep>? motionSequence;
  AvatarBodyPose? bodyPose;
  AvatarGaze? gaze;
  String? handIkTarget;
  Map<String, dynamic>? handIkOpts;

  @override
  Future<void> clearGaze() async {
    gaze = null;
  }

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async {
    final error = transientError;
    if (error != null) throw error;
    primitiveType = type;
    primitiveOpts = opts;
  }

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async {
    motionType = type;
    motionOpts = opts;
  }

  @override
  Future<void> playMotionSequence(List<AvatarMotionStep> steps) async {
    motionSequence = steps;
  }

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async {
    final error = transientError;
    if (error != null) throw error;
    clipId = id;
    clipOpts = opts;
  }

  @override
  Future<void> resume() async {}

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {}

  @override
  Future<void> setFraming(String mode) async {}

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async {}

  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {}

  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async {
    handIkTarget = target;
    handIkOpts = opts;
  }

  @override
  Future<void> setBodyPose(AvatarBodyPose pose) async {
    bodyPose = pose;
  }

  @override
  Future<void> setGaze(AvatarGaze gaze) async {
    this.gaze = gaze;
  }

  @override
  Future<void> setMouthOpen(double value) async {}

  @override
  Future<void> startLipSync(
    List<double> envelope, {
    int frameRate = 30,
  }) async {}

  @override
  Future<void> stopLipSync() async {}
}
