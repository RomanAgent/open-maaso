import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_zh.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/body/avatar_body_intent_policy.dart';

void main() {
  const energy = {'gentle', 'moderate', 'high'};
  const speechGestures = {
    'explain',
    'palms_open',
    'point_small',
    'chest',
    'none',
  };

  for (final locale in [AppLocale.zh, AppLocale.en]) {
    group('avatar performance prompt ${locale.code}', () {
      test(
        'both action examples expose the same bounded semantic contract',
        () {
          final text = AgentPromptCatalog.text(
            'runtime.structured.output_contract',
            locale: locale,
          );
          final contract =
              jsonDecode(text.substring(text.indexOf('{')))
                  as Map<String, dynamic>;
          final examples = (contract['actions'] as List)
              .cast<Map<String, dynamic>>()
              .where(
                (action) =>
                    action['type'] == 'avatar.act' ||
                    action['type'] == 'avatar.react',
              )
              .toList();
          expect(examples.map((action) => action['type']).toSet(), {
            'avatar.act',
            'avatar.react',
          });
          for (final example in examples) {
            expect((example['energy'] as String).split('|').toSet(), energy);
            expect(
              (example['gesture'] as String).split('|').toSet(),
              containsAll(speechGestures),
            );
            expect(example, containsPair('intensity', .7));
            expect(example, containsPair('durationMs', 3500));
            expect(example, contains('mood'));
            expect(example.keys, isNot(contains('bone')));
            expect(example.keys, isNot(contains('clip')));
            expect(jsonEncode(example), isNot(contains('annie_')));

            for (final level in energy) {
              final action = <String, Object?>{
                ...example,
                'mood': 'happy',
                'gesture': 'palms_open',
                'gaze': 'user',
                if (example.containsKey('posture')) 'posture': 'none',
                'style': 'normal',
                'energy': level,
                'intensity': .65,
              };
              final response = AgentActionEnvelope.parse(
                jsonEncode({
                  'reply': locale == AppLocale.zh
                      ? '我来解释一下。'
                      : 'Let me explain.',
                  'actions': [action],
                }),
              );
              expect(response.actions, hasLength(1));
              final parsed = response.actions.single;
              expect(parsed.data['energy'], level);
              if (parsed.type == 'avatar.act') {
                final cue = AvatarAct.fromJson(parsed.data);
                expect(cue.energy, level);
                expect(cue.gesture, 'palms_open');
                expect(cue.intensity, .65);
              } else {
                final cue = AvatarReaction.fromJson(parsed.data);
                expect(cue.energy, level);
                expect(cue.gesture, 'palms_open');
                expect(cue.intensity, .65);
              }
            }
          }
        },
      );

      test('fast reply body metadata preserves the same optional energy', () {
        final resource = locale == AppLocale.zh
            ? runtimePromptsZh
            : runtimePromptsEn;
        final persona = resource['runtime.persona.system']!;
        final marker = RegExp(
          r'<body_intent>(\{[^\n]+\})</body_intent>',
        ).firstMatch(persona)!;
        final schema = jsonDecode(marker.group(1)!) as Map<String, dynamic>;
        expect((schema['energy'] as String).split('|').toSet(), energy);
        expect(schema['durationMs'], 3500);
        expect(
          (schema['gesture'] as String).split('|').toSet(),
          containsAll(speechGestures),
        );
        for (final gesture in speechGestures) {
          final admitted = AvatarBodyIntentPolicy.normalize({
            'mood': 'happy',
            'gesture': gesture,
            'gaze': 'user',
            'posture': 'none',
            'style': 'normal',
            'energy': 'moderate',
            'intensity': .65,
            'durationMs': 3500,
          });
          expect(admitted, isNotNull, reason: gesture);
          expect(admitted!['gesture'], gesture);
          expect(admitted['energy'], 'moderate');
        }
        expect(
          AvatarBodyIntentPolicy.normalize({
            'mood': 'happy',
            'gesture': 'explain',
            'energy': 'unbounded',
          }),
          isNull,
        );
        expect(
          AvatarBodyIntentPolicy.normalize({
            'mood': 'happy',
            'gesture': 'annie_g_open_both',
            'energy': 'moderate',
          }),
          isNull,
        );
        expect(
          AvatarBodyIntentPolicy.normalize({
            'mood': 'curious',
            'gesture': 'explain',
            'energy': 'gentle',
          }),
          containsPair('energy', 'gentle'),
        );
      });

      test('instructions keep first speech independent and task ownership', () {
        final text = AgentPromptCatalog.text(
          'runtime.structured.body_language',
          locale: locale,
        );
        if (locale == AppLocale.zh) {
          expect(text, contains('普通回合通常零到一个提示'));
          expect(text, contains('同一个响应'));
          expect(text, contains('不另发情绪或动作分析请求'));
          expect(text, contains('不等待动作再说话'));
          expect(text, contains('省略 energy'));
          expect(text, contains('不得打断正在执行的任务或家具姿态'));
          expect(text, contains('嘴型始终由 TTS 负责'));
        } else {
          expect(text, contains('normally zero or one cue per turn'));
          expect(text, contains('with this same reply'));
          expect(text, contains('do not request a separate emotion/animation'));
          expect(text, contains('or wait for movement before speaking'));
          expect(text, contains('omit energy for face/gaze only'));
          expect(text, contains('interrupt existing tasks/furniture'));
          expect(text, contains('TTS always owns the mouth'));
        }
        expect(text, isNot(contains('annie_')));
      });
    });
  }

  test('speech canonical commands keep exactly five bounded wire keys', () {
    for (final level in energy) {
      final command = AvatarBodyGestureCommand(
        'explain',
        energy: level,
        intensity: .65,
        emotion: 'happy',
      );
      expect(command.toCanonicalJson(), {
        'channel': 'bodyGesture',
        'gesture': 'explain',
        'energy': level,
        'intensity': .65,
        'emotion': 'happy',
      });
    }
    expect(AvatarBodyGestureCommand('nod').toCanonicalJson(), {
      'channel': 'bodyGesture',
      'gesture': 'nod',
    });
    expect(
      () => AvatarBodyGestureCommand(
        'explain',
        energy: 'unbounded',
        intensity: .65,
        emotion: 'happy',
      ),
      throwsArgumentError,
    );
    expect(
      () => AvatarBodyGestureCommand(
        'explain',
        energy: 'moderate',
        intensity: double.infinity,
        emotion: 'happy',
      ),
      throwsArgumentError,
    );
  });

  test('omitting optional energy retains face and gaze only semantics', () {
    final act = AvatarAct.fromJson({
      'mood': 'calm',
      'gesture': 'none',
      'gaze': 'user',
    });
    final reaction = AvatarReaction.fromJson({
      'mood': 'calm',
      'gesture': 'none',
      'gaze': 'user',
    });
    expect(act.energy, isNull);
    expect(act.inferGesture, isFalse);
    expect(reaction.energy, isNull);
    expect(reaction.gesture, 'none');
  });
}
