import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  late SkillUsageService usage;
  late SkillManager manager;
  late _UsageProbe probe;
  var current = true;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    current = true;
    database = await databaseFactoryMemory.openDatabase(
      'skill-usage-execution',
    );
    usage = await SkillUsageService(
      database: database,
      accountScopeDigest: 'a' * 64,
      isCurrent: () => current,
    ).init(observeLifecycle: false);
    probe = _UsageProbe();
    manager = SkillManager(
      usageService: usage,
      useAppServicesActionContractFallback: false,
    )..registerSkill(probe);
  });
  tearDown(() async {
    await usage.shutdown();
    await appServices.reset();
    await database.close();
    await databaseFactoryMemory.deleteDatabase('skill-usage-execution');
  });

  Future<void> settle() async => usage.whenSettled;

  test(
    'discovery and invalid arguments never count; native and delayed do',
    () async {
      manager.toNativeTools(locale: AppLocale.en);
      manager.validateToolArguments('skill_usageprobe_read', {
        'value': 'private',
      });
      expect(usage.forSkill('UsageProbe').started, 0);
      await expectLater(
        manager.invokeTool('skill_usageprobe_read', {}),
        throwsA(isA<InvalidToolArgumentsException>()),
      );
      expect(probe.calls, 0);
      await manager.invokeTool('skill_usageprobe_read', {'value': 'private'});
      await manager.invokeTool('skill_usageprobe_read', {
        'value': 'private',
      }, channel: ActionContractChannel.delayedTool);
      await settle();
      expect(probe.calls, 2);
      expect(usage.forSkill('UsageProbe').started, 2);
      expect(usage.entries.value.map((entry) => entry.channel).toSet(), {
        SkillUsageChannel.native,
        SkillUsageChannel.delayed,
      });
    },
  );

  test(
    'strict missing permission/contract dependency cannot count as use',
    () async {
      final pinned = SkillManager(
        usageService: usage,
        requirePinnedActionContract: true,
        useAppServicesActionContractFallback: false,
      )..registerSkill(probe);
      final output = await pinned.invokeTool('skill_usageprobe_read', {
        'value': 'private',
      });
      expect(jsonDecode(output)['code'], 'contract_dependency_unavailable');
      await settle();
      expect(probe.calls, 0);
      expect(usage.entries.value, isEmpty);
    },
  );

  test(
    'structured grant counts one dispatch; absent or stale grant counts zero',
    () async {
      final registry = LazyHostSkillRegistry(
        agentId: 'self',
        specs: [
          SkillSpec(
            id: 'usage_probe',
            name: 'probe',
            description: 'probe',
            icon: Icons.info,
            color: Colors.blue,
            category: SkillCategory.core,
            isCore: true,
            factory: (_) => probe,
            hostRouting: HostSkillRoutingManifest(
              skillName: 'UsageProbe',
              summary: 'Read a probe',
              methods: ['read'],
              nativeMethods: ['read'],
            ),
          ),
        ],
      );
      final grant = registry.issueGrant(
        TurnSkillGrant.bounded(
          rankedDescriptors: registry.descriptors(),
          maxSkills: 1,
          promptBudget: 4096,
        ),
      );
      final envelope = AgentActionEnvelope.parse(
        jsonEncode({
          'reply': '',
          'actions': [
            {
              'type': 'skill.call',
              'tool': 'skill_usageprobe_read',
              'args': {'value': 'private'},
            },
          ],
        }),
      );
      AgentActionExecutor executor(ExecutableHostGrant supplied) =>
          AgentActionExecutor(
            agentId: 'self',
            skillManager: manager,
            locale: AppLocale.en,
            executableHostGrant: supplied,
            useAppServicesActionContractFallback: false,
          );
      final denied = await executor(ExecutableHostGrant.none).execute(envelope);
      expect(denied.ok, isFalse);
      expect(probe.calls, 0);
      final accepted = await executor(grant).execute(envelope);
      expect(accepted.ok, isTrue);
      await settle();
      expect(probe.calls, 1);
      expect(usage.entries.value.single.channel, SkillUsageChannel.structured);
      expect(usage.forSkill('UsageProbe').started, 1);
      registry.invalidate();
      expect((await executor(grant).execute(envelope)).ok, isFalse);
      await settle();
      expect(usage.forSkill('UsageProbe').started, 1);
    },
  );

  test(
    'local manifest counts once and unconfirmed writes do not count',
    () async {
      const manifest = LocalSkillManifest(
        id: 'usage_probe',
        skillName: 'UsageProbe',
        method: 'read',
        summary: 'Read a probe',
        tags: ['probe'],
        risk: LocalSkillRisk.read,
        argsSchema: _schema,
      );
      final invoker = LocalSkillInvoker(skillManager: manager);
      expect(
        (await invoker.invoke(manifest, {'value': 'private'})).status,
        LocalSkillResultStatus.ok,
      );
      const write = LocalSkillManifest(
        id: 'usage_probe',
        skillName: 'UsageProbe',
        method: 'read',
        summary: 'Write probe',
        tags: ['probe'],
        risk: LocalSkillRisk.sideEffect,
        argsSchema: _schema,
      );
      expect(
        (await invoker.invoke(write, {'value': 'private'})).status,
        LocalSkillResultStatus.commitRequired,
      );
      await settle();
      expect(probe.calls, 1);
      expect(usage.forSkill('UsageProbe').started, 1);
      expect(usage.entries.value.single.channel, SkillUsageChannel.local);
    },
  );

  test(
    'execution errors count actual uses and preserve original failures',
    () async {
      final failure = StateError('private failure sentinel');
      probe.failure = failure;
      await expectLater(
        manager.invokeTool('skill_usageprobe_read', {'value': 'private'}),
        throwsA(same(failure)),
      );
      await settle();
      expect(usage.forSkill('UsageProbe').started, 1);
      expect(usage.forSkill('UsageProbe').failed, 1);
      probe.failure = null;
      probe.output = '{"error":"private rejected detail"}';
      expect(
        await manager.invokeTool('skill_usageprobe_read', {'value': 'private'}),
        probe.output,
      );
      await settle();
      expect(usage.forSkill('UsageProbe').failed, 2);
      final rows = await StoreRef<String, Map<String, Object?>>(
        'skill_usage_totals.v1',
      ).find(database);
      final stored = jsonEncode(rows.map((r) => r.value).toList());
      expect(stored, isNot(contains('private')));
      expect(stored, isNot(contains('sentinel')));
    },
  );

  test(
    'an old manager and pending callback cannot charge the replacement account',
    () async {
      final pending = Completer<String>();
      probe.pending = pending.future;
      final call = manager.invokeTool('skill_usageprobe_read', {
        'value': 'private',
      });
      await settle();
      expect(usage.forSkill('UsageProbe').started, 1);
      usage.retire();
      current = false;
      final replacement = await SkillUsageService(
        database: database,
        accountScopeDigest: 'b' * 64,
        isCurrent: () => true,
      ).init(observeLifecycle: false);
      appServices.put<SkillUsageService>(replacement);
      pending.complete('{"ok":true}');
      await call;
      await replacement.whenSettled;
      expect(replacement.entries.value, isEmpty);
      probe.pending = null;
      await manager.invokeTool('skill_usageprobe_read', {'value': 'private'});
      await replacement.whenSettled;
      expect(replacement.entries.value, isEmpty);
      final fresh = SkillManager(
        usageService: replacement,
        useAppServicesActionContractFallback: false,
      )..registerSkill(probe);
      await fresh.invokeTool('skill_usageprobe_read', {'value': 'private'});
      await replacement.whenSettled;
      expect(replacement.forSkill('UsageProbe').started, 1);
      await replacement.shutdown();
    },
  );

  test(
    'unavailable bookkeeping never prevents or changes a handler result',
    () async {
      await database.close();
      final output = await manager.invokeTool('skill_usageprobe_read', {
        'value': 'private',
      });
      await settle();
      expect(output, '{"ok":true}');
      expect(probe.calls, 1);
      expect(usage.unavailable.value, isTrue);
    },
  );
}

const _schema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'value': {'type': 'string'},
  },
  'required': ['value'],
  'additionalProperties': false,
};

class _UsageProbe extends AgentSkill {
  int calls = 0;
  Object? failure;
  String output = '{"ok":true}';
  Future<String>? pending;
  @override
  String get skillName => 'UsageProbe';
  @override
  String get description => 'Read a bounded usage probe';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'read': (_) {
      calls++;
      if (failure case final error?) throw error;
      return pending ?? output;
    },
  };
  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {'read': _schema};
}
