import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:maaso/src/features/agent/data/skills/tool_call_runner.dart';

void main() {
  group('SkillManager native schema gate', () {
    test(
      'valid arguments execute once and preserve the raw legacy result',
      () async {
        final skill = _SchemaProbeSkill();
        final manager = SkillManager()..registerSkill(skill);
        final tool = SkillManager.nativeToolName(skill, 'strict');
        const arguments = <String, dynamic>{
          'command': 'open',
          'count': 2,
          'selector': <String, dynamic>{'id': 'door-1'},
        };

        final result = await manager.invokeTool(tool, arguments);

        expect(result, _SchemaProbeSkill.legacyResult);
        expect(skill.handlerCalls, 1);
        expect(jsonDecode(skill.lastArgumentsJson!), arguments);
      },
    );

    test('all supported constraint failures stop before the handler', () async {
      final invalidArguments = <Map<String, dynamic>>[
        <String, dynamic>{
          'count': 2,
          'selector': <String, dynamic>{'id': 'door-1'},
        },
        <String, dynamic>{
          'command': 'open',
          'count': 'two',
          'selector': <String, dynamic>{'id': 'door-1'},
        },
        <String, dynamic>{
          'command': 'unknown',
          'count': 2,
          'selector': <String, dynamic>{'id': 'door-1'},
        },
        <String, dynamic>{
          'command': 'open',
          'count': 9,
          'selector': <String, dynamic>{'id': 'door-1'},
        },
        <String, dynamic>{
          'command': 'open',
          'count': 2,
          'selector': <String, dynamic>{},
        },
        <String, dynamic>{
          'command': 'open',
          'count': 2,
          'selector': <String, dynamic>{'id': 'door-1'},
          'secret-user-value': true,
        },
      ];

      for (final arguments in invalidArguments) {
        final skill = _SchemaProbeSkill();
        final manager = SkillManager()..registerSkill(skill);
        final tool = SkillManager.nativeToolName(skill, 'strict');

        await expectLater(
          manager.invokeTool(tool, arguments),
          throwsA(isA<InvalidToolArgumentsException>()),
          reason: '$arguments must fail closed',
        );
        expect(skill.handlerCalls, 0);
      }
    });

    test('malformed host schema fails closed without echoing values', () async {
      final skill = _SchemaProbeSkill(malformedSchema: true);
      final manager = SkillManager()..registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'strict');

      Object? error;
      try {
        await manager.invokeTool(tool, const <String, dynamic>{
          'command': 'secret-user-value',
        });
      } catch (caught) {
        error = caught;
      }

      expect(error, isA<InvalidToolArgumentsException>());
      expect(error.toString(), isNot(contains('secret-user-value')));
      expect(skill.handlerCalls, 0);
    });

    test(
      'runner maps non-object and schema mismatch to bad_arguments',
      () async {
        final skill = _SchemaProbeSkill();
        final manager = SkillManager()..registerSkill(skill);
        final openTool = SkillManager.nativeToolName(skill, 'open');
        final strictTool = SkillManager.nativeToolName(skill, 'strict');
        final client = _TwoCallClient(<ToolCall>[
          ToolCall(id: 'array', name: openTool, argumentsJson: '[]'),
          ToolCall(
            id: 'mismatch',
            name: strictTool,
            argumentsJson: jsonEncode(const <String, Object?>{
              'command': 'secret-user-value',
            }),
          ),
        ]);

        final result = await ToolCallRunner(
          client: client,
          skillManager: manager,
          maxRounds: 2,
        ).run(messages: <Message>[Message.user('run tools')]);

        expect(result.stoppedReason, 'text_only');
        expect(client.toolResults, hasLength(2));
        for (final toolResult in client.toolResults) {
          expect(jsonDecode(toolResult), <String, dynamic>{
            'error': 'bad_arguments',
          });
          expect(toolResult, isNot(contains('secret-user-value')));
        }
        expect(skill.handlerCalls, 0);
      },
    );
  });
}

final class _SchemaProbeSkill extends AgentSkill {
  _SchemaProbeSkill({this.malformedSchema = false});

  static const legacyResult = 'legacy-result-is-preserved';

  final bool malformedSchema;
  int handlerCalls = 0;
  String? lastArgumentsJson;

  @override
  String get skillName => 'SchemaProbe';

  @override
  String get description => 'Schema validation probe.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'open': _handle,
    'strict': _handle,
  };

  dynamic _handle(List<dynamic> arguments) {
    handlerCalls++;
    lastArgumentsJson = arguments.single as String;
    return legacyResult;
  }

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    'open': const <String, dynamic>{'type': 'object'},
    'strict': malformedSchema
        ? const <String, dynamic>{'type': 'object', 'unsupported': true}
        : const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'command': <String, dynamic>{
                'type': 'string',
                'enum': <String>['open', 'close'],
              },
              'count': <String, dynamic>{
                'type': 'integer',
                'minimum': 1,
                'maximum': 3,
              },
              'selector': <String, dynamic>{
                'type': 'object',
                'properties': <String, dynamic>{
                  'id': <String, dynamic>{'type': 'string'},
                  'name': <String, dynamic>{'type': 'string'},
                },
                'anyOf': <Object?>[
                  <String, dynamic>{
                    'required': <String>['id'],
                  },
                  <String, dynamic>{
                    'required': <String>['name'],
                  },
                ],
                'additionalProperties': false,
              },
            },
            'required': <String>['command', 'count', 'selector'],
            'additionalProperties': false,
          },
  };
}

final class _TwoCallClient extends LLMClient {
  _TwoCallClient(this.calls);

  final List<ToolCall> calls;
  int _round = 0;
  List<String> toolResults = const <String>[];

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) async {
    if (_round++ == 0) {
      return ChatTurnResult(content: '', toolCalls: calls);
    }
    toolResults = messages
        .where((message) => message.role == 'tool')
        .map((message) => message.content)
        .toList(growable: false);
    return ChatTurnResult(content: 'done', toolCalls: const <ToolCall>[]);
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnsupportedError('not used');
}
