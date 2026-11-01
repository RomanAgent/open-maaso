import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  tearDown(appServices.reset);

  test('registry grant allows only its exact selected host binding', () async {
    final skillA = _RecordingSkill('A');
    final skillB = _RecordingSkill('B');
    final issued = _issueGrant(
      catalogSkills: <_RecordingSkill>[skillA, skillB],
      selectedSkillName: 'A',
    );
    final manager = SkillManager()
      ..registerSkill(skillA)
      ..registerSkill(skillB);
    final executor = AgentActionExecutor(
      agentId: 'self',
      skillManager: manager,
      locale: AppLocale.en,
      executableHostGrant: issued.grant,
    );

    final allowed = await executor.execute(_callEnvelope(skillA));
    final denied = await executor.execute(
      _callEnvelope(
        skillB,
        args: const <String, Object?>{'confirmed': true},
        confirmed: true,
      ),
    );

    expect(allowed.ok, isTrue);
    expect(_skillPayload(allowed), {'status': 'ok', 'skill': 'A'});
    expect(denied.ok, isFalse);
    expect(denied.errors.single, contains('skill_not_granted'));
    expect(skillA.callCount, 1);
    expect(skillB.callCount, 0);
  });

  test('copied same-id prompt grant cannot authorize a host skill', () async {
    final hostSkill = _RecordingSkill('A');
    final registry = LazyHostSkillRegistry(
      agentId: 'self',
      specs: <SkillSpec>[_spec(hostSkill)],
    );
    final owned = registry.descriptorFor('A')!;
    final copied = SkillDescriptor(
      id: owned.id,
      summary: owned.summary,
      terms: owned.terms,
      promptCost: owned.promptCost,
    );
    final manager = SkillManager()..registerSkill(hostSkill);
    final executor = AgentActionExecutor(
      agentId: 'self',
      skillManager: manager,
      locale: AppLocale.en,
      executableHostGrant: registry.issueGrant(_promptGrant(copied)),
    );

    final result = await executor.execute(_callEnvelope(hostSkill));

    expect(result.ok, isFalse);
    expect(result.errors.single, contains('skill_not_granted'));
    expect(hostSkill.callCount, 0);
  });

  test('missing and stale executable grants fail closed', () async {
    final skill = _RecordingSkill('A');
    final issued = _issueGrant(
      catalogSkills: <_RecordingSkill>[skill],
      selectedSkillName: 'A',
    );
    final manager = SkillManager()..registerSkill(skill);

    final missing = await AgentActionExecutor(
      agentId: 'self',
      skillManager: manager,
      locale: AppLocale.en,
    ).execute(_callEnvelope(skill));
    issued.registry.reload(const <String>{});
    final stale = await AgentActionExecutor(
      agentId: 'self',
      skillManager: manager,
      locale: AppLocale.en,
      executableHostGrant: issued.grant,
    ).execute(_callEnvelope(skill));

    expect(missing.ok, isFalse);
    expect(stale.ok, isFalse);
    expect(missing.errors.single, contains('skill_not_granted'));
    expect(stale.errors.single, contains('skill_not_granted'));
    expect(skill.callCount, 0);
  });

  test(
    'a native handler StateError is never retried through legacy fallback',
    () async {
      final skill = _RecordingSkill('A', throwStateError: true);
      final issued = _issueGrant(
        catalogSkills: <_RecordingSkill>[skill],
        selectedSkillName: 'A',
      );
      final manager = SkillManager()..registerSkill(skill);
      final executor = AgentActionExecutor(
        agentId: 'self',
        skillManager: manager,
        locale: AppLocale.en,
        executableHostGrant: issued.grant,
      );

      final result = await executor.execute(_callEnvelope(skill));

      expect(result.ok, isFalse);
      expect(skill.callCount, 1);
    },
  );

  test('exact one-shot handler observes the executor turn locale', () async {
    final skill = _RecordingSkill('A');
    final issued = _issueGrant(
      catalogSkills: <_RecordingSkill>[skill],
      selectedSkillName: 'A',
    );
    final result = await AgentActionExecutor(
      agentId: 'self',
      skillManager: SkillManager()..registerSkill(skill),
      locale: AppLocale.zh,
      executableHostGrant: issued.grant,
    ).execute(_callEnvelope(skill));

    expect(result.ok, isTrue);
    expect(skill.seenLocale, AppLocale.zh);
  });
}

({LazyHostSkillRegistry registry, ExecutableHostGrant grant}) _issueGrant({
  required List<_RecordingSkill> catalogSkills,
  required String selectedSkillName,
}) {
  final registry = LazyHostSkillRegistry(
    agentId: 'self',
    specs: <SkillSpec>[for (final skill in catalogSkills) _spec(skill)],
  );
  final descriptor = registry.descriptorFor(selectedSkillName)!;
  return (
    registry: registry,
    grant: registry.issueGrant(_promptGrant(descriptor)),
  );
}

SkillSpec _spec(_RecordingSkill skill) => SkillSpec(
  id: skill.skillName.toLowerCase(),
  name: skill.skillName,
  description: skill.description,
  icon: Icons.extension_rounded,
  color: Colors.blue,
  category: SkillCategory.knowledge,
  factory: (_) => skill,
  hostRouting: HostSkillRoutingManifest(
    skillName: skill.skillName,
    summary: skill.description,
    methods: const <String>['run'],
    nativeMethods: const <String>['run'],
    terms: <String>[skill.skillName],
  ),
);

TurnSkillGrant _promptGrant(SkillDescriptor descriptor) =>
    TurnSkillGrant.bounded(
      rankedDescriptors: <SkillDescriptor>[descriptor],
      maxSkills: 1,
      promptBudget: 1024,
    );

AgentActionEnvelope _callEnvelope(
  _RecordingSkill skill, {
  Map<String, Object?> args = const <String, Object?>{},
  bool confirmed = false,
}) => AgentActionEnvelope.parse(
  jsonEncode(<String, Object?>{
    'reply': '',
    'actions': <Object?>[
      <String, Object?>{
        'type': 'skill.call',
        'tool': SkillManager.nativeToolName(skill, 'run'),
        'args': args,
        if (confirmed) 'confirmed': true,
      },
    ],
  }),
);

Map<String, dynamic> _skillPayload(AgentActionExecutionResult result) {
  final observation = result.observations.single;
  final separator = observation.indexOf('=>');
  expect(separator, greaterThanOrEqualTo(0), reason: observation);
  return Map<String, dynamic>.from(
    jsonDecode(observation.substring(separator + 2).trim()) as Map,
  );
}

class _RecordingSkill extends AgentSkill {
  _RecordingSkill(this._name, {this.throwStateError = false});

  final String _name;
  final bool throwStateError;
  int callCount = 0;
  AppLocale? seenLocale;

  @override
  String get skillName => _name;

  @override
  String get description => 'Recording test skill $_name';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'run': (_) {
      callCount++;
      seenLocale = AgentPromptCatalog.currentLocale;
      if (throwStateError) throw StateError('handler failed');
      return jsonEncode(<String, Object?>{'status': 'ok', 'skill': _name});
    },
  };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    'run': const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  };
}
