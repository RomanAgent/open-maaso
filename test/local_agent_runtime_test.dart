import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/local_agent_runtime.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/local_model_action_planner.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/local_skill_retriever.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/scheduled_task_skill.dart';

void main() {
  test('local retriever returns only local eligible skill manifests', () {
    final manifests = LocalSkillManifest.fromCatalog(SkillCatalog.all);
    final results = LocalSkillRetriever(
      manifests,
    ).retrieve('帮我新增待办清单', maxResults: 3);

    expect(results.map((m) => m.id), contains('todo'));
    expect(
      results.map((m) => m.id).toSet().intersection({
        'calc',
        'weather',
        'trip_plan',
        'set_theme',
      }),
      isEmpty,
    );
    expect(results.map((m) => m.id), isNot(contains('live_space')));
    expect(results.every((m) => m.localEligible), isTrue);
    expect(results.length, lessThanOrEqualTo(3));
  });

  test('local invoker blocks side-effect skills until confirmation', () async {
    final manager = SkillManager()
      ..registerSkill(ScheduledTaskSkill(agentId: 'self'));
    final manifest = SkillCatalog.byId('scheduled_task')!.localManifest!;

    final result = await LocalSkillInvoker(skillManager: manager).invoke(
      manifest,
      {'when': '08:00', 'prompt': 'drink water', 'repeat': 'once'},
    );

    expect(result.status, LocalSkillResultStatus.commitRequired);
    expect(result.skillId, 'scheduled_task');
    expect(result.output, contains('confirmation_required'));
  });

  test('local invoker can call read-only shared skill handlers', () async {
    final manager = SkillManager()..registerSkill(_SnapshotProbeSkill());

    final result = await LocalSkillInvoker(
      skillManager: manager,
    ).invoke(_snapshotManifest, {'key': 'active'});

    expect(result.status, LocalSkillResultStatus.ok);
    expect(jsonDecode(result.output), containsPair('value', 'ready'));
  });

  test('local runtime runs call observe finish without AgentRuntime', () async {
    final manager = SkillManager()..registerSkill(_SnapshotProbeSkill());
    final planner = _ScriptedPlanner([
      LocalAgentAction.call('snapshot_probe', {'key': 'active'}),
      LocalAgentAction.finish('状态已就绪。'),
    ]);

    final result = await LocalAgentRuntime(
      skillManager: manager,
      manifests: [_snapshotManifest],
      planner: planner,
    ).run('查询快照状态');

    expect(result.status, LocalAgentRunStatus.finished);
    expect(result.finalText, '状态已就绪。');
    expect(result.observations.single.skillId, 'snapshot_probe');
    expect(
      jsonDecode(result.observations.single.output),
      containsPair('value', 'ready'),
    );
  });

  test(
    'local runtime refuses skills outside retrieved local candidates',
    () async {
      final manager = SkillManager()..registerSkill(_SnapshotProbeSkill());
      final planner = _ScriptedPlanner([
        LocalAgentAction.call('app_control', {'action': 'undeclared'}),
        LocalAgentAction.finish('这个需要云端。'),
      ]);

      final result = await LocalAgentRuntime(
        skillManager: manager,
        manifests: [_snapshotManifest],
        planner: planner,
      ).run('查询快照状态');

      expect(result.status, LocalAgentRunStatus.finished);
      expect(result.observations.single.status, LocalSkillResultStatus.denied);
      expect(
        result.observations.single.output,
        contains('skill_not_in_local_candidates'),
      );
    },
  );

  test('model action planner parses compact call JSON', () async {
    final planner = LocalModelActionPlanner(
      complete: (_) async =>
          '{"type":"call","skill":"snapshot_probe","args":{"key":"active"}}',
    );

    final action = await planner.next(
      LocalAgentTurn(
        userText: '查询快照状态',
        step: 1,
        candidates: [_snapshotManifest],
        observations: const [],
      ),
    );

    expect(action.type, LocalAgentActionType.call);
    expect(action.skillId, 'snapshot_probe');
    expect(action.args, containsPair('key', 'active'));
  });

  test(
    'model action planner keeps prompt scoped to retrieved skills',
    () async {
      List<({String role, String content})>? messages;
      final planner = LocalModelActionPlanner(
        complete: (m) async {
          messages = m;
          return '{"type":"finish","text":"done"}';
        },
      );

      await planner.next(
        LocalAgentTurn(
          userText: '新增待办',
          step: 1,
          candidates: [SkillCatalog.byId('todo')!.localManifest!],
          observations: const [],
        ),
      );

      final prompt = messages!.map((m) => m.content).join('\n');
      expect(prompt, contains('"id":"todo"'));
      expect(prompt, isNot(contains('"id":"calc"')));
      expect(prompt, isNot(contains('"id":"weather"')));
      expect(prompt, isNot(contains('"id":"live_space"')));
      expect(prompt.length, lessThan(1800));
    },
  );

  test('fast local routing never suggests retired skills', () async {
    final router = HeuristicLocalBackend();
    for (final request in [
      '深圳明天天气怎么样？',
      'Plan a spontaneous trip',
      '计算 1+2',
      'Switch to dark theme',
    ]) {
      final result = await router.route(request);
      expect(
        result.needsTools.toSet().intersection({
          'calc',
          'weather',
          'trip_plan',
          'set_theme',
        }),
        isEmpty,
        reason: request,
      );
    }
    final creation = await router.route('生成一个天气小程序');
    expect(creation.needsTools, contains('freeform_surface'));
  });
}

// A test-only read boundary, never registered in the production SkillCatalog.
const _snapshotManifest = LocalSkillManifest(
  id: 'snapshot_probe',
  skillName: 'SnapshotProbe',
  method: 'read',
  summary: 'Read a bounded snapshot key.',
  tags: ['snapshot', '快照', 'status', '状态'],
  risk: LocalSkillRisk.read,
  argsSchema: {
    'type': 'object',
    'properties': {
      'key': {'type': 'string'},
    },
    'required': ['key'],
  },
);

class _SnapshotProbeSkill extends AgentSkill {
  @override
  String get skillName => 'SnapshotProbe';
  @override
  String get description => 'Test-only snapshot reader';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'read': (args) {
      final input = jsonDecode(args.single as String) as Map;
      return jsonEncode({'key': input['key'], 'value': 'ready'});
    },
  };
}

class _ScriptedPlanner implements LocalAgentPlanner {
  _ScriptedPlanner(this._actions);

  final List<LocalAgentAction> _actions;

  @override
  Future<LocalAgentAction> next(LocalAgentTurn turn) async {
    return _actions[turn.step - 1];
  }
}
