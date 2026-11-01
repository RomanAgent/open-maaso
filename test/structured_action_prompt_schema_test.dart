import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/delayed_choice_executor.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_skill_descriptor_factory.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill_structured_action_schema.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:maaso/src/features/agent/data/skills/tool_call_runner.dart';

void main() {
  test(
    'prompt-only schemas remain structured-action metadata, not native tools',
    () async {
      final skill = _PromptOnlySurfaceSkill();
      final schemas = skill.modelStructuredActionPromptSchemas;
      final manager = SkillManager()..registerSkill(skill);
      final editTool = SkillManager.nativeToolName(skill, 'editSurface');

      expect(schemas.methodNames, <String>['editSurface', 'revertSurface']);
      expect(schemas.schemaFor('editSurface')?['required'], <String>[
        'surfaceId',
      ]);
      expect(schemas.schemaFor('listSurfaces'), isNull);
      expect(skill.nativeToolSchemas, isNull);
      expect(manager.hasNativeTools, isFalse);
      expect(manager.toNativeTools(), isEmpty);
      expect(manager.skillOwnerForTool(editTool), same(skill));
      expect(manager.methodNameForTool(editTool), 'editSurface');
      await expectLater(
        manager.invokeTool(editTool, const <String, dynamic>{}),
        throwsStateError,
      );
      expect(skill.callCount, 0);
    },
  );

  test(
    'native schemas remain visible to both existing channels by default',
    () {
      final skill = _NativeSkill();

      expect(skill.modelStructuredActionPromptSchemas.methodNames, <String>[
        'run',
      ]);
      expect(
        skill.modelStructuredActionPromptSchemas.schemaFor('run'),
        skill.nativeToolSchemas['run'],
      );
      expect((SkillManager()..registerSkill(skill)).hasNativeTools, isTrue);
    },
  );

  test(
    'tool-call and delayed-choice runners cannot invoke prompt-only methods',
    () async {
      final skill = _PromptOnlySurfaceSkill();
      final manager = SkillManager()..registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'editSurface');
      final toolClient = _ForcedToolClient(tool);

      final toolResult = await ToolCallRunner(
        client: toolClient,
        skillManager: manager,
        maxRounds: 2,
      ).run(messages: <Message>[Message.user('try the hidden tool')]);

      expect(toolResult.stoppedReason, 'text_only');
      expect(toolClient.firstRoundTools, isEmpty);
      expect(toolClient.toolResult, contains('unknown_tool'));
      expect(skill.callCount, 0);

      final delayedClient = _ForcedToolClient(tool);
      final delayed = DelayedChoiceExecutor();
      final delayedResult = await delayed.run(
        client: delayedClient,
        skillManager: manager,
        messages: <Message>[Message.user('try the hidden tool')],
        maxRounds: 2,
      );

      expect(delayedResult.stoppedReason, 'text_only');
      expect(delayedClient.firstRoundTools, isEmpty);
      expect(delayedClient.toolResult, contains('unknown_tool'));
      expect(delayed.pending, isEmpty);
      expect(skill.callCount, 0);
    },
  );

  test(
    'lazy host validation accepts structured-only schemas with zero native methods',
    () {
      final skill = _PromptOnlySurfaceSkill();
      final registry = LazyHostSkillRegistry(
        agentId: 'self',
        specs: <SkillSpec>[_promptOnlySurfaceSpec(skill)],
      );
      final descriptor = registry.descriptorFor('FreeformSurface')!;

      final grant = registry.issueGrant(_promptGrant(descriptor));
      final editTool = HostSkillRoutingManifest.nativeToolName(
        'FreeformSurface',
        'editSurface',
      );

      expect(grant.activatedSkills.single, same(skill));
      expect(
        grant.authorize(agentId: 'self', tool: editTool)?.method,
        'editSurface',
      );
      expect(
        grant.authorize(agentId: 'self', tool: editTool)?.usesJsonArguments,
        isFalse,
      );
      expect(registry.activeCount, 1);
    },
  );

  test('descriptor prompt cost includes structured-only schemas', () {
    final withSchema = AgentSkillDescriptorFactory.fromSkill(
      _PromptOnlySurfaceSkill(),
    );
    final withoutSchema = AgentSkillDescriptorFactory.fromSkill(
      _SchemaFreeSurfaceSkill(),
    );

    expect(withSchema.promptCost, greaterThan(withoutSchema.promptCost));
  });
}

TurnSkillGrant _promptGrant(SkillDescriptor descriptor) =>
    TurnSkillGrant.bounded(
      rankedDescriptors: <SkillDescriptor>[descriptor],
      maxSkills: 1,
      promptBudget: 4096,
    );

SkillSpec _promptOnlySurfaceSpec(_PromptOnlySurfaceSkill skill) => SkillSpec(
  id: 'surface',
  name: 'surface',
  description: 'surface',
  icon: Icons.layers_rounded,
  color: Colors.blue,
  category: SkillCategory.expression,
  factory: (_) => skill,
  hostRouting: HostSkillRoutingManifest(
    skillName: 'FreeformSurface',
    summary: 'Edit or revert the visible Surface.',
    methods: const <String>[
      'showSurface',
      'editSurface',
      'listSurfaces',
      'reopenSurface',
      'revertSurface',
    ],
    nativeMethods: const <String>[],
  ),
);

class _PromptOnlySurfaceSkill extends AgentSkill
    implements StructuredActionPromptSchemaProvider {
  int callCount = 0;

  @override
  String get skillName => 'FreeformSurface';

  @override
  String get description => 'Edit or revert the visible Surface.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    for (final method in const <String>[
      'showSurface',
      'editSurface',
      'listSurfaces',
      'reopenSurface',
      'revertSurface',
    ])
      method: (_) {
        callCount++;
        return '{}';
      },
  };

  @override
  StructuredActionPromptSchemas get structuredActionPromptSchemas =>
      StructuredActionPromptSchemas(<String, Map<String, dynamic>>{
        'editSurface': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'surfaceId': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['surfaceId'],
          'additionalProperties': false,
        },
        'revertSurface': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'surfaceId': <String, dynamic>{'type': 'string'},
            'revisionId': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['surfaceId'],
          'additionalProperties': false,
        },
      });
}

final class _SchemaFreeSurfaceSkill extends AgentSkill {
  @override
  String get skillName => 'FreeformSurface';

  @override
  String get description => 'Edit or revert the visible Surface.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'editSurface': (_) => '{}',
    'revertSurface': (_) => '{}',
  };
}

final class _NativeSkill extends AgentSkill {
  @override
  String get skillName => 'Native';

  @override
  String get description => 'Native tool.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'run': (_) => '{}',
  };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    'run': const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  };
}

final class _ForcedToolClient extends LLMClient {
  _ForcedToolClient(this.toolName);

  final String toolName;
  int _round = 0;
  List<Map<String, dynamic>> firstRoundTools = const <Map<String, dynamic>>[];
  String? toolResult;

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) async {
    if (_round++ == 0) {
      firstRoundTools = List<Map<String, dynamic>>.from(tools);
      return ChatTurnResult(
        content: '',
        toolCalls: <ToolCall>[
          ToolCall(
            id: 'forced-call',
            name: toolName,
            argumentsJson: jsonEncode(<String, Object?>{
              'surfaceId': 'surface-1',
            }),
          ),
        ],
      );
    }
    toolResult = messages
        .where((message) => message.role == 'tool')
        .map((message) => message.content)
        .last;
    return ChatTurnResult(content: 'done', toolCalls: const <ToolCall>[]);
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async =>
      throw UnsupportedError('not used');
}
