import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/prompts/agent_skill_prompt_metadata.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_camera_director.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_skill_descriptor_factory.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skills/avatar_camera_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

const _tool = 'skill_avatarcamera_setframing';

void main() {
  tearDown(appServices.reset);

  for (final mode in ['face', 'bust', 'full', 'auto']) {
    test('native tool delegates $mode and preserves director result', () async {
      final director = _RecordingCameraDirector();
      final skill = AvatarCameraSkill(director: director);
      final manager = SkillManager()..registerSkill(skill);
      final output = jsonDecode(
        await manager.invokeTool(_tool, {'mode': mode}),
      );

      expect(director.requests, [(mode, 'self')]);
      expect(output, director.lastResult);
      expect(output['automatic'], mode == 'auto');
      expect(output['idleTimeoutSeconds'], 45);
    });
  }

  test('only exact semantic arguments reach the director', () async {
    final director = _RecordingCameraDirector();
    final skill = AvatarCameraSkill(director: director);
    final manager = SkillManager()..registerSkill(skill);
    final invalid = <Map<String, dynamic>>[
      {},
      {'mode': 'head'},
      {'mode': 'upper_body'},
      {'mode': 'FACE'},
      {'mode': ' face'},
      {'mode': null},
      {'mode': 1},
      {'mode': 'face', 'fov': 20},
      {'mode': 'face', 'target': 'another-agent'},
      {'mode': 'face', 'durationMs': 10000},
    ];
    for (final args in invalid) {
      await expectLater(manager.invokeTool(_tool, args), throwsException);
      final direct = jsonDecode(
        await skill.methods['setFraming']!([jsonEncode(args)]),
      );
      expect(direct, {
        'ok': false,
        'error': 'invalid_arguments',
      }, reason: '$args');
    }
    for (final args in <List<dynamic>>[
      [],
      ['not json'],
      ['[]'],
      ['null'],
      ['{"mode":"face"}', 'extra'],
    ]) {
      final output = jsonDecode(await skill.methods['setFraming']!(args));
      expect(output, {'ok': false, 'error': 'invalid_arguments'});
    }
    expect(director.requests, isEmpty);
  });

  test('another agent cannot control the owner camera', () async {
    final director = _RecordingCameraDirector();
    final manager = SkillManager()
      ..registerSkill(AvatarCameraSkill(agentId: 'other', director: director));
    expect(jsonDecode(await manager.invokeTool(_tool, {'mode': 'face'})), {
      'ok': false,
      'error': 'camera_self_only',
    });
    expect(director.requests, isEmpty);
  });

  test(
    'missing director fails without creating a renderer or service',
    () async {
      final manager = SkillManager()..registerSkill(AvatarCameraSkill());
      expect(jsonDecode(await manager.invokeTool(_tool, {'mode': 'face'})), {
        'ok': false,
        'error': 'camera_unavailable',
      });
      expect(appServices.isRegistered<AvatarCameraDirector>(), isFalse);
    },
  );

  test('director rejection and exceptions never report success', () async {
    final rejection = {'ok': false, 'error': 'camera_surface_unavailable'};
    final director = _RecordingCameraDirector(result: rejection);
    final manager = SkillManager()
      ..registerSkill(AvatarCameraSkill(director: director));
    expect(
      jsonDecode(await manager.invokeTool(_tool, {'mode': 'full'})),
      rejection,
    );
    director.throwOnRequest = true;
    expect(jsonDecode(await manager.invokeTool(_tool, {'mode': 'auto'})), {
      'ok': false,
      'error': 'camera_failed',
    });
  });

  test(
    'local invocation is reversible and needs no extra confirmation',
    () async {
      final director = _RecordingCameraDirector();
      final manager = SkillManager()
        ..registerSkill(AvatarCameraSkill(director: director));
      final spec = SkillCatalog.byId('avatar_camera')!;
      expect(spec.isCore, isTrue);
      expect(spec.requiredPlatformCapabilities, {
        AppActionCapability.unityAvatar,
      });
      expect(spec.localManifest!.requiresConfirmation, isFalse);
      final result = await LocalSkillInvoker(
        skillManager: manager,
      ).invoke(spec.localManifest!, {'mode': 'bust'});
      expect(result.status, LocalSkillResultStatus.ok);
      expect(jsonDecode(result.output), director.lastResult);
      expect(director.requests, [('bust', 'self')]);
    },
  );

  test('catalog factory binds the owning agent without resolving services', () {
    final skill = SkillCatalog.byId('avatar_camera')!.factory!('other');
    expect(skill, isA<AvatarCameraSkill>());
    expect((skill as AvatarCameraSkill).agentId, 'other');
    expect(appServices.isRegistered<AvatarCameraDirector>(), isFalse);
  });

  test(
    'camera uses the existing JSON skill action and respects action scopes',
    () {
      final source = jsonEncode({
        'reply': '',
        'actions': [
          {
            'type': 'skill.call',
            'tool': _tool,
            'args': {'mode': 'face'},
          },
        ],
      });
      final envelope = AgentActionEnvelope.parse(source);
      expect(envelope.actions.single.type, 'skill.call');
      expect(envelope.actions.single['tool'], _tool);
      for (final scope in [
        AgentActionScope.proactivePresence,
        AgentActionScope.notificationInteraction,
      ]) {
        expect(
          () => AgentActionEnvelope.parse(source, scope: scope),
          throwsA(isA<AgentActionProtocolException>()),
        );
      }
    },
  );

  for (final locale in [AppLocale.en, AppLocale.zh]) {
    test(
      'bilingual camera metadata retains exact modes for ${locale.name}',
      () {
        final skill = AvatarCameraSkill();
        final manager = SkillManager()..registerSkill(skill);
        final tool = manager.toNativeTools(locale: locale).single;
        final function = tool['function'] as Map;
        expect(function['name'], _tool);
        final schema = function['parameters'] as Map;
        expect((schema['properties'] as Map)['mode']['enum'], [
          'face',
          'bust',
          'full',
          'auto',
        ]);
        expect(schema['additionalProperties'], isFalse);
        final description = AgentSkillPromptMetadata.description(
          skill,
          locale: locale,
        );
        expect(description, contains('45'));
        final cjk = RegExp(r'[\u4e00-\u9fff]');
        expect(cjk.hasMatch(description), locale == AppLocale.zh);
        expect(
          cjk.hasMatch(function['description'] as String),
          locale == AppLocale.zh,
        );
        expect(
          AgentPromptCatalog.text('runtime.response_tracks', locale: locale),
          contains(_tool),
        );
      },
    );

    for (final lazy in [true, false]) {
      test('natural camera requests retrieve the $locale/$lazy skill', () {
        final descriptors = SkillCatalog.all
            .where((spec) => spec.factory != null && spec.hostRouting != null)
            .map(
              (spec) => lazy
                  ? AgentSkillDescriptorFactory.fromManifest(
                      spec.hostRouting!,
                      locale: locale,
                    )
                  : AgentSkillDescriptorFactory.fromSkill(
                      spec.factory!('self'),
                      locale: locale,
                    ),
            );
        final router = SkillRouter(index: SkillIndex(descriptors));
        for (final text in [
          '让我看看你的脸',
          '镜头切到上半身',
          '我想看看你的全身',
          '恢复自动镜头',
          'Show me your face',
          'Show your upper body',
          'Show your full body',
          'Switch back to automatic framing',
        ]) {
          final decision = router.route(text);
          expect(
            decision.disposition,
            SkillRouteDisposition.selected,
            reason: text,
          );
          expect(
            decision.topMatch?.descriptor.id,
            'AvatarCamera',
            reason: text,
          );
        }
        for (final text in ['用摄像头拍照', 'take a photo of your face']) {
          expect(router.route(text).grant.allows('AvatarCamera'), isFalse);
        }
      });
    }
  }
}

class _RecordingCameraDirector implements AvatarCameraDirector {
  _RecordingCameraDirector({this.result});

  final Map<String, dynamic>? result;
  final requests = <(String, String)>[];
  Map<String, dynamic>? lastResult;
  bool throwOnRequest = false;

  @override
  Future<Map<String, dynamic>> setFraming(
    String mode, {
    String agentId = 'self',
  }) async {
    requests.add((mode, agentId));
    if (throwOnRequest) throw StateError('renderer internals');
    return lastResult =
        result ??
        {
          'ok': true,
          'mode': mode,
          'framing': switch (mode) {
            'face' => 'head',
            'bust' => 'upper_body',
            _ => 'hero_full_body',
          },
          'automatic': mode == 'auto',
          'idleTimeoutSeconds': 45,
        };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
