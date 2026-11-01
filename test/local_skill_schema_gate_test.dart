import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/todo_service.dart';
import 'package:maaso/src/features/agent/application/local_agent_runtime.dart';
import 'package:maaso/src/features/agent/application/local_model_action_planner.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/skills/todo_skill.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

void main() {
  tearDown(appServices.reset);

  group('LocalSkillInvoker schema gate', () {
    test('validates the host-fixed final argument snapshot', () async {
      final skill = _ProbeSkill();
      final result = await _invoker(skill).invoke(
        _manifest(
          fixedArgs: const <String, dynamic>{'page': 'settings'},
          argsSchema: const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'page': <String, dynamic>{'type': 'string', 'const': 'settings'},
            },
            'required': <String>['page'],
            'additionalProperties': false,
          },
        ),
        const <String, dynamic>{'page': 'planner-override'},
      );

      expect(result.status, LocalSkillResultStatus.ok);
      expect(skill.handlerCalls, 1);
      expect(jsonDecode(skill.lastArgumentsJson!), <String, dynamic>{
        'page': 'settings',
      });
    });

    test(
      'invalid side-effect arguments fail before confirmation and handler',
      () async {
        final skill = _ProbeSkill();
        final result = await _invoker(skill).invoke(
          _manifest(
            risk: LocalSkillRisk.sideEffect,
            argsSchema: const <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{
                'message': <String, dynamic>{'type': 'string'},
              },
              'required': <String>['message'],
              'additionalProperties': false,
            },
          ),
          const <String, dynamic>{'message': 7, 'secret-user-value': true},
        );

        expect(result.status.name, 'invalidArguments');
        expect(jsonDecode(result.output), <String, dynamic>{
          'status': 'invalid_arguments',
          'code': 'invalid_arguments',
          'retryable': false,
        });
        expect(result.output, isNot(contains('secret-user-value')));
        expect(skill.handlerCalls, 0);
      },
    );

    test('malformed host schema fails with the same redacted result', () async {
      final skill = _ProbeSkill();
      final result = await _invoker(skill).invoke(
        _manifest(
          argsSchema: const <String, dynamic>{
            'type': 'object',
            'unsupported': true,
          },
        ),
        const <String, dynamic>{'secret-user-value': true},
      );

      expect(result.status.name, 'invalidArguments');
      expect(jsonDecode(result.output), <String, dynamic>{
        'status': 'invalid_arguments',
        'code': 'invalid_arguments',
        'retryable': false,
      });
      expect(result.output, isNot(contains('secret-user-value')));
      expect(skill.handlerCalls, 0);
    });

    test('confirmation and handler use the same merged arguments', () async {
      final skill = _ProbeSkill();
      final invoker = _invoker(skill);
      final manifest = _manifest(
        risk: LocalSkillRisk.sideEffect,
        fixedArgs: const <String, dynamic>{'page': 'settings'},
        argsSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'page': <String, dynamic>{'type': 'string'},
            'message': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['page', 'message'],
          'additionalProperties': false,
        },
      );
      const plannerArgs = <String, dynamic>{
        'page': 'planner-override',
        'message': 'hello',
      };

      final pending = await invoker.invoke(manifest, plannerArgs);
      final executed = await invoker.invoke(
        manifest,
        plannerArgs,
        confirmed: true,
      );

      final confirmedArgs = jsonDecode(pending.output)['args'];
      expect(confirmedArgs, <String, dynamic>{
        'page': 'settings',
        'message': 'hello',
      });
      expect(jsonDecode(skill.lastArgumentsJson!), confirmedArgs);
      expect(executed.status, LocalSkillResultStatus.ok);
      expect(skill.handlerCalls, 1);
    });
  });

  group('LocalModelActionPlanner argument envelope', () {
    test(
      'rejects array and missing call args instead of coercing to empty',
      () {
        for (final raw in <String>[
          '{"type":"call","skill":"todo","args":[]}',
          '{"type":"call","skill":"todo"}',
        ]) {
          final action = LocalModelActionPlanner.parseAction(raw);
          expect(action.type, LocalAgentActionType.ask);
        }
      },
    );
  });

  group('Todo local object contract', () {
    test(
      'object items execute locally without requiring confirmation',
      () async {
        final todos = appServices.put(TodoService());
        final skill = TodoSkill(agentId: 'self');
        final manager = SkillManager()..registerSkill(skill);
        const manifest = LocalSkillManifest(
          id: 'todo',
          skillName: 'Todo',
          method: 'todo_addMany',
          summary: 'Create a visible local checklist for multi-step work.',
          tags: <String>['todo'],
          risk: LocalSkillRisk.writeLocal,
          argsSchema: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'items': <String, dynamic>{
                'type': 'array',
                'items': <String, dynamic>{'type': 'string'},
                'minItems': 1,
              },
            },
            'required': <String>['items'],
            'additionalProperties': false,
          },
        );

        final result = await LocalSkillInvoker(skillManager: manager).invoke(
          manifest,
          const <String, dynamic>{
            'items': <String>['inspect', 'implement'],
          },
        );

        expect(result.status, LocalSkillResultStatus.ok);
        expect(jsonDecode(result.output), containsPair('status', 'ok'));
        expect(todos.items.map((item) => item.text), <String>[
          'inspect',
          'implement',
        ]);
      },
    );

    test('legacy top-level array remains accepted by the handler', () {
      final todos = appServices.put(TodoService());
      final skill = TodoSkill(agentId: 'self');

      final output = skill.methods['todo_addMany']!(<dynamic>[
        jsonEncode(<String>['legacy-a', 'legacy-b']),
      ]);

      expect(jsonDecode(output as String), containsPair('status', 'ok'));
      expect(todos.items.map((item) => item.text), <String>[
        'legacy-a',
        'legacy-b',
      ]);
    });
  });
}

LocalSkillInvoker _invoker(AgentSkill skill) =>
    LocalSkillInvoker(skillManager: SkillManager()..registerSkill(skill));

LocalSkillManifest _manifest({
  required Map<String, dynamic> argsSchema,
  Map<String, dynamic> fixedArgs = const <String, dynamic>{},
  LocalSkillRisk risk = LocalSkillRisk.read,
}) => LocalSkillManifest(
  id: 'probe',
  skillName: 'Probe',
  method: 'run',
  summary: 'probe',
  tags: const <String>['probe'],
  argsSchema: argsSchema,
  fixedArgs: fixedArgs,
  risk: risk,
);

final class _ProbeSkill extends AgentSkill {
  int handlerCalls = 0;
  String? lastArgumentsJson;

  @override
  String get skillName => 'Probe';

  @override
  String get description => 'Probe local schema validation.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        'run': (arguments) {
          handlerCalls += 1;
          lastArgumentsJson = arguments.single as String;
          return '{"status":"ok"}';
        },
      };
}
