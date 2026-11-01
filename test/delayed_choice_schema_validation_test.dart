import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/delayed_choice_executor.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  test('SkillManager validation preflight is public and side-effect free', () {
    final skill = _DelayedProbeSkill();
    final manager = SkillManager()..registerSkill(skill);
    final tool = SkillManager.nativeToolName(skill, 'update');

    manager.validateToolArguments(tool, _validArguments());

    expect(skill.handlerCalls, 0);
    expect(
      () => manager.validateToolArguments(tool, const <String, dynamic>{}),
      throwsA(isA<InvalidToolArgumentsException>()),
    );
    expect(skill.handlerCalls, 0);
  });

  test(
    'invalid side-effect arguments fail before proposal or execution',
    () async {
      final skill = _DelayedProbeSkill();
      final manager = SkillManager()..registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'update');
      final client = _ToolBatchClient(<ToolCall>[
        ToolCall(
          id: 'schema-mismatch',
          name: tool,
          argumentsJson: jsonEncode(<String, dynamic>{
            'options': <String, dynamic>{
              'tags': <String>['warm'],
              'metadata': <String, dynamic>{'room': 'desk'},
            },
          }),
        ),
        ToolCall(id: 'non-object', name: tool, argumentsJson: '[]'),
      ]);
      final executor = DelayedChoiceExecutor();

      final result = await executor.run(
        client: client,
        skillManager: manager,
        messages: <Message>[Message.user('update the lamp')],
        maxRounds: 2,
        locale: AppLocale.en,
      );

      expect(result.stoppedReason, 'text_only');
      expect(client.toolResults, hasLength(2));
      for (final output in client.toolResults) {
        expect(jsonDecode(output), <String, dynamic>{'error': 'bad_arguments'});
      }
      expect(executor.pending, isEmpty);
      expect(skill.handlerCalls, 0);
    },
  );

  test('pending arguments are deeply frozen at proposal time', () async {
    final skill = _DelayedProbeSkill();
    final manager = SkillManager()..registerSkill(skill);
    final tool = SkillManager.nativeToolName(skill, 'update');
    final client = _ToolBatchClient(<ToolCall>[
      ToolCall(
        id: 'valid-update',
        name: tool,
        argumentsJson: jsonEncode(_validArguments()),
      ),
    ]);
    final executor = DelayedChoiceExecutor();

    await executor.run(
      client: client,
      skillManager: manager,
      messages: <Message>[Message.user('update the lamp')],
      maxRounds: 2,
      locale: AppLocale.en,
    );

    expect(executor.pending, hasLength(1));
    expect(skill.handlerCalls, 0);
    final args = executor.pending.single.args;
    final options = args['options']! as Map<String, dynamic>;
    final tags = options['tags']! as List<dynamic>;
    final metadata = options['metadata']! as Map<String, dynamic>;
    expect(() => args['target'] = 'other', throwsUnsupportedError);
    expect(() => options['extra'] = true, throwsUnsupportedError);
    expect(() => tags.add('cool'), throwsUnsupportedError);
    expect(() => metadata['room'] = 'bed', throwsUnsupportedError);
  });

  test(
    'valid side effect commits once with legacy JSON and explicit locale',
    () async {
      final skill = _DelayedProbeSkill();
      final manager = SkillManager()..registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'update');
      final client = _ToolBatchClient(<ToolCall>[
        ToolCall(
          id: 'valid-update',
          name: tool,
          argumentsJson: jsonEncode(_validArguments()),
        ),
      ]);
      final executor = DelayedChoiceExecutor();

      await executor.run(
        client: client,
        skillManager: manager,
        messages: <Message>[Message.user('update the lamp')],
        maxRounds: 2,
        locale: AppLocale.zh,
      );

      final proposal = jsonDecode(client.toolResults.single) as Map;
      expect(proposal['status'], 'commit_required');
      expect(proposal['tool'], tool);
      expect(proposal['risk'], 'side_effect');
      expect(
        proposal['message'],
        AgentPromptCatalog.text(
          'app.delayed_choice.confirmation',
          locale: AppLocale.zh,
        ),
      );
      expect(executor.pending, hasLength(1));
      expect(skill.handlerCalls, 0);

      final branchId = executor.pending.single.id;
      final committed =
          jsonDecode(await executor.commitLatest(manager, locale: AppLocale.zh))
              as Map<String, dynamic>;

      expect(committed['status'], 'committed');
      expect(committed['branchId'], branchId);
      expect(committed['tool'], tool);
      expect(committed['result'], <String, dynamic>{
        'ok': true,
        'target': 'lamp',
        'locale': 'zh',
      });
      expect(executor.pending, isEmpty);
      expect(skill.handlerCalls, 1);
      expect(skill.lastArguments, _validArguments());
    },
  );

  test(
    'commit revalidates schema drift and keeps the pending branch',
    () async {
      final skill = _DelayedProbeSkill();
      final manager = SkillManager()..registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'update');
      final client = _ToolBatchClient(<ToolCall>[
        ToolCall(
          id: 'valid-update',
          name: tool,
          argumentsJson: jsonEncode(_validArguments()),
        ),
      ]);
      final executor = DelayedChoiceExecutor();

      await executor.run(
        client: client,
        skillManager: manager,
        messages: <Message>[Message.user('update the lamp')],
        maxRounds: 2,
        locale: AppLocale.en,
      );
      final branchId = executor.pending.single.id;
      skill.updateSchema['required'] = <String>[
        'target',
        'options',
        'newRequiredField',
      ];

      final rejected =
          jsonDecode(
                await executor.commit(branchId, manager, locale: AppLocale.en),
              )
              as Map<String, dynamic>;

      expect(rejected, <String, dynamic>{
        'status': 'error',
        'branchId': branchId,
        'error': 'bad_arguments',
      });
      expect(executor.pending.single.id, branchId);
      expect(skill.handlerCalls, 0);
    },
  );

  test(
    'read-only calls still execute and unknown tools stay unknown',
    () async {
      final skill = _DelayedProbeSkill();
      final manager = SkillManager()..registerSkill(skill);
      final readTool = SkillManager.nativeToolName(skill, 'read');
      const unknownTool = 'skill_missing_update';
      final client = _ToolBatchClient(<ToolCall>[
        ToolCall(
          id: 'read',
          name: readTool,
          argumentsJson: jsonEncode(_validArguments()),
        ),
        ToolCall(id: 'unknown', name: unknownTool, argumentsJson: '{}'),
      ]);
      final executor = DelayedChoiceExecutor();

      await executor.run(
        client: client,
        skillManager: manager,
        messages: <Message>[Message.user('read and update')],
        maxRounds: 2,
        locale: AppLocale.en,
      );

      expect(jsonDecode(client.toolResults.first), <String, dynamic>{
        'ok': true,
        'target': 'lamp',
        'locale': 'en',
      });
      expect(jsonDecode(client.toolResults.last), <String, dynamic>{
        'error': 'unknown_tool',
        'name': unknownTool,
      });
      expect(executor.pending, isEmpty);
      expect(skill.handlerCalls, 1);
    },
  );
}

Map<String, dynamic> _validArguments() => <String, dynamic>{
  'target': 'lamp',
  'options': <String, dynamic>{
    'tags': <String>['warm'],
    'metadata': <String, dynamic>{'room': 'desk'},
  },
};

final class _DelayedProbeSkill extends AgentSkill {
  final Map<String, dynamic> updateSchema = <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'target': <String, dynamic>{'type': 'string', 'minLength': 1},
      'options': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'tags': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
            'minItems': 1,
          },
          'metadata': <String, dynamic>{
            'type': 'object',
            'additionalProperties': <String, dynamic>{'type': 'string'},
          },
        },
        'required': <String>['tags', 'metadata'],
        'additionalProperties': false,
      },
    },
    'required': <String>['target', 'options'],
    'additionalProperties': false,
  };

  int handlerCalls = 0;
  Map<String, dynamic>? lastArguments;

  @override
  String get skillName => 'DelayedProbe';

  @override
  String get description => 'Delayed choice schema probe.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        'update': _handle,
        'read': _handle,
      };

  dynamic _handle(List<dynamic> arguments) {
    handlerCalls += 1;
    lastArguments = Map<String, dynamic>.from(
      jsonDecode(arguments.single as String) as Map,
    );
    return jsonEncode(<String, dynamic>{
      'ok': true,
      'target': lastArguments!['target'],
      'locale': AgentPromptCatalog.currentLocale.name,
    });
  }

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas =>
      <String, Map<String, dynamic>>{
        'update': updateSchema,
        'read': updateSchema,
      };
}

final class _ToolBatchClient extends LLMClient {
  _ToolBatchClient(this.calls);

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
