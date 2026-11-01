import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';

void main() {
  const gameJavaScript = '''
const help = 'The Claw. name is only an example in this game.';
const score = {player: 0, cpu: 0};
document.querySelector('#restart').addEventListener('click', () => {
  score.player = 0;
  score.cpu = 0;
});
''';
  const instructions = '''
Restart resets the local game. Documentation example:
```javascript
const label = "Claw. is a literal label";
```
''';
  final gameResponse = jsonEncode(<String, Object?>{
    'reply': 'The game is ready; Claw. is mentioned in its help text.',
    'actions': <Object?>[
      <String, Object?>{
        'type': 'surface.show',
        'surface': <String, Object?>{
          'title': 'Local opponent game',
          'experienceType': 'game',
          'kind': 'webApp',
          'rendering': 'dom',
          'html': '<main><button id="restart">Restart</button></main>',
          'css': 'main { color: #141820; }',
          'js': gameJavaScript,
          'skillInstructions': instructions,
          'manifest': <String, Object?>{
            'events': <Object?>[],
            'actions': <Object?>[],
          },
        },
      },
    ],
  });

  group('structured response data boundary', () {
    test(
      'preserves escaped game source and Markdown documentation as data',
      () {
        final envelope = AgentActionEnvelope.parse(gameResponse);
        final surface = envelope.actions.single['surface'] as Map;

        expect(envelope.reply, contains('Claw.'));
        expect(envelope.actions.single.type, 'surface.show');
        expect(
          surface['html'],
          '<main><button id="restart">Restart</button></main>',
        );
        expect(surface['js'], gameJavaScript);
        expect(surface['skillInstructions'], instructions);
      },
    );

    test(
      'accepts literal legacy names in reply and ordinary action strings',
      () {
        final envelope = AgentActionEnvelope.parse(
          jsonEncode(<String, Object?>{
            'reply': 'The old name Claw. is ordinary text.',
            'actions': <Object?>[
              <String, Object?>{
                'type': 'voice.speak',
                'text':
                    'Explain ```javascript examples without executing them.',
              },
            ],
          }),
        );

        expect(envelope.reply, 'The old name Claw. is ordinary text.');
        expect(envelope.actions.single['text'], contains('```javascript'));
      },
    );

    for (final language in <String>['json', 'JSON', '']) {
      test('accepts a complete $language fence containing game data', () {
        final envelope = AgentActionEnvelope.parse(
          '```$language\n$gameResponse\n```',
        );
        final surface = envelope.actions.single['surface'] as Map;

        expect(surface['js'], gameJavaScript);
        expect(surface['skillInstructions'], instructions);
      });
    }

    test(
      'rejects outer legacy calls even when their argument is valid JSON',
      () {
        for (final source in <String>[
          'Claw.call($gameResponse);',
          'Claw.finish($gameResponse)',
          '```javascript\nClaw.call($gameResponse);\n```',
          '```js\nClaw.call($gameResponse);\n```',
        ]) {
          expect(
            () => AgentActionEnvelope.parse(source),
            _throwsProtocolCode('legacy_script'),
            reason: source,
          );
        }
      },
    );

    test('rejects JavaScript fences containing only a JSON-shaped object', () {
      for (final language in <String>['javascript', 'js', 'JAVASCRIPT']) {
        expect(
          () => AgentActionEnvelope.parse(
            '```$language\n{"reply":"ready","actions":[]}\n```',
          ),
          _throwsProtocolCode('legacy_script'),
        );
      }
    });

    test(
      'rejects other executable wrappers instead of extracting their JSON',
      () {
        expect(
          () => AgentActionEnvelope.parse(
            'window.show({"reply":"ready","actions":[]});',
          ),
          _throwsProtocolCode('no_json_object'),
        );
      },
    );

    test('rejects prose surrounding bare or fenced JSON', () {
      for (final source in <String>[
        'Here is the result: {"reply":"ready","actions":[]}',
        '{"reply":"ready","actions":[]} Finished.',
        'Here is the result:\n```json\n{"reply":"ready","actions":[]}\n```',
        '```json\n{"reply":"ready","actions":[]}\n```\nFinished.',
      ]) {
        expect(
          () => AgentActionEnvelope.parse(source),
          throwsA(isA<AgentActionProtocolException>()),
          reason: source,
        );
      }
    });

    test('rejects executable suffixes after bare or fenced JSON', () {
      const json = '{"reply":"ready","actions":[]}';
      for (final source in <String>[
        '$json\nClaw.finish("ready");',
        '$json\nconsole.log("ready");',
        '$json\n```javascript\nconsole.log("ready");\n```',
        '```json\n$json\n```\nconsole.log("ready");',
        '```json\n$json\n```\n```js\nClaw.finish("ready");\n```',
      ]) {
        expect(
          () => AgentActionEnvelope.parse(source),
          throwsA(isA<AgentActionProtocolException>()),
          reason: source,
        );
      }
    });

    test('rejects multiple objects and mixed fence blocks', () {
      const json = '{"reply":"ready","actions":[]}';
      for (final source in <String>[
        '$json\n$json',
        '```json\n$json\n```\n```json\n$json\n```',
      ]) {
        expect(
          () => AgentActionEnvelope.parse(source),
          _throwsProtocolCode('invalid_json'),
        );
      }
    });

    test(
      'reports malformed object JSON rather than scanning its inner strings',
      () {
        expect(
          () => AgentActionEnvelope.parse(
            '{"reply":"unfinished Claw. ```javascript',
          ),
          _throwsProtocolCode('invalid_json'),
        );
      },
    );

    test('keeps action list and action object validation unchanged', () {
      expect(
        () => AgentActionEnvelope.parse('{"reply":"ready","actions":{}}'),
        _throwsProtocolCode('actions_not_list'),
      );
      expect(
        () => AgentActionEnvelope.parse('{"reply":"ready","actions":[42]}'),
        _throwsProtocolCode('action_not_object'),
      );
    });

    test('keeps restricted-scope action checks after data parsing', () {
      final envelope = AgentActionEnvelope.parse(
        '{"reply":"Claw. is text","actions":[{"type":"emotion.set","emotion":"calm"}]}',
        scope: AgentActionScope.proactivePresence,
      );
      expect(envelope.reply, 'Claw. is text');
      expect(
        () => AgentActionEnvelope.parse(
          '{"reply":"Claw. is text","actions":[{"type":"surface.show"}]}',
          scope: AgentActionScope.proactivePresence,
        ),
        _throwsProtocolCode('proactive_action_not_allowed'),
      );
    });
  });

  test(
    'both repair prompts distinguish JSON content from external scripts',
    () {
      for (final locale in <AppLocale>[AppLocale.en, AppLocale.zh]) {
        final prompt = AgentPromptCatalog.text(
          'runtime.protocol.repair',
          locale: locale,
          params: <String, Object?>{'error': 'invalid_json'},
        );
        expect(prompt, contains('invalid_json'));
        expect(prompt, contains('"reply"'));
        expect(prompt, contains('"actions"'));
        expect(prompt, contains('surface.show'));
        expect(prompt, contains('surface.js'));
        expect(prompt, contains('skillInstructions'));
        expect(prompt, isNot(contains('不要包含 Markdown 代码围栏、脚本或')));
        expect(
          prompt,
          isNot(contains('Do not include markdown fences, scripts,')),
        );
      }
    },
  );
}

Matcher _throwsProtocolCode(String code) => throwsA(
  isA<AgentActionProtocolException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);
