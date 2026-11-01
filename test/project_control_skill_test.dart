import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_skill_prompt_metadata.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skills/project_control_skill.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/project_build/application/project_applet_control_service.dart';
import 'package:maaso/src/features/project_build/data/project_applet_action_journal.dart';
import 'package:sembast/sembast_memory.dart';
import 'project_applet_control_test.dart' show AppletTestHost;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late ProjectAppletControlService control;
  late AppletTestHost host;
  late ProjectControlSkill skill;
  late LazyHostSkillRegistry registry;
  late AgentActionExecutor executor;
  var sequence = 0;
  setUp(() async {
    appServices.testMode = true;
    await appServices.reset();
    final scopes = appServices.put(AccountStorageScopeService());
    final mount = scopes.mount(
      AccountStorageScope(environmentKey: 'test', accountUuid: 'owner'),
    );
    final scope = mount.scope.storageNamespace;
    db = await databaseFactoryMemory.openDatabase(
      'project-skill-${sequence++}',
    );
    host = AppletTestHost()..controlScopeKey = scope;
    control = ProjectAppletControlService(
      scopeKey: scope,
      appletScopeKey: 'origin|owner',
      journal: ProjectAppletActionJournal(
        database: db,
        scopeKey: scope,
        repositoryScopeKey: 'test|owner',
        processId: 'process',
        isCurrent: () => scopes.isCurrent(mount),
      ),
      isCurrent: () => scopes.isCurrent(mount),
      isForeground: () => true,
      commandTimeout: const Duration(seconds: 2),
    )..registerHost(host);
    skill = ProjectControlSkill(control: control);
    registry = LazyHostSkillRegistry(
      agentId: 'self',
      specs: [
        SkillSpec(
          id: 'project_control_test',
          name: 'Project control',
          description: skill.description,
          icon: Icons.smart_toy_outlined,
          color: Colors.blue,
          category: SkillCategory.core,
          isCore: true,
          factory: (_) => skill,
          hostRouting: HostSkillRoutingManifest(
            skillName: skill.skillName,
            summary: skill.description,
            methods: skill.methods.keys,
            nativeMethods: skill.nativeToolSchemas.keys,
            terms: const ['project control'],
          ),
        ),
      ],
    );
    final grant = registry.issueGrant(
      TurnSkillGrant.bounded(
        rankedDescriptors: <SkillDescriptor>[
          registry.descriptorFor(skill.skillName)!,
        ],
        maxSkills: 1,
        promptBudget: 8192,
      ),
    );
    final manager = SkillManager()..registerSkill(grant.activatedSkills.single);
    executor = AgentActionExecutor(
      agentId: 'self',
      skillManager: manager,
      locale: AppLocale.en,
      executableHostGrant: grant,
    );
  });
  tearDown(() async {
    registry.invalidate();
    await control.deactivateAndDrain();
    await db.close();
    await appServices.reset();
  });
  Future<AgentActionExecutionResult> execute(
    String method, [
    Map<String, Object?> args = const {},
  ]) => executor.execute(
    AgentActionEnvelope(
      reply: '',
      actions: [
        AgentAction(
          type: 'skill.call',
          data: {
            'tool': SkillManager.nativeToolName(skill, method),
            'args': args,
          },
        ),
      ],
    ),
  );
  Map<String, Object?> response(AgentActionExecutionResult result) {
    expect(result.ok, isTrue);
    expect(result.observations, hasLength(1));
    final text = result.observations.single;
    return Map<String, Object?>.from(
      jsonDecode(text.substring(text.indexOf('=> ') + 3)) as Map,
    );
  }

  Future<Map<String, Object?>> observation() async => Map<String, Object?>.from(
    response(await execute('observe'))['data']! as Map,
  );
  Map<String, Object?> action(Map<String, Object?> observation) => {
    'requestId': 'skill_request_01',
    'observationId': observation['observationId'],
    'actionId': 'app.set',
    'args': {'value': 1},
    'expectedStateVersion': 1,
  };
  Future<void> waitDispatch() async {
    for (var i = 0; i < 100 && host.dispatched == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(host.dispatched, isNotNull);
  }

  test(
    'catalog exposes four bounded native methods and no grant or local-agent bypass',
    () {
      final spec = SkillCatalog.all.singleWhere(
        (s) => s.id == 'project_control',
      );
      expect(spec.localManifest, isNull);
      expect(spec.factory!('self'), isA<ProjectControlSkill>());
      expect(
        skill.methods.keys,
        unorderedEquals(['describe', 'observe', 'act', 'receipt']),
      );
      expect(skill.nativeToolSchemas.keys, unorderedEquals(skill.methods.keys));
      expect(skill.description, contains('untrusted'));
      expect(
        skill.nativeToolSchemas.values.every(
          (s) => s['additionalProperties'] == false,
        ),
        isTrue,
      );
      for (final locale in [AppLocale.en, AppLocale.zh]) {
        expect(
          AgentSkillPromptMetadata.description(skill, locale: locale),
          isNotEmpty,
        );
        for (final method in skill.methods.keys) {
          expect(
            AgentSkillPromptMetadata.methodDescription(
              skill,
              method,
              locale: locale,
            ),
            isNotEmpty,
          );
          expect(
            AgentSkillPromptMetadata.schema(
              skill,
              method,
              skill.nativeToolSchemas[method]!,
              locale: locale,
            ),
            isNotEmpty,
          );
        }
      }
    },
  );
  test(
    'describe reports missing native permission and no method can manufacture it',
    () async {
      final status = response(await execute('describe'));
      expect((status['data']! as Map)['status'], 'native_grant_required');
      expect(
        response(await execute('observe'))['error'],
        'native_grant_required',
      );
      expect(control.currentGrant('self'), isNull);
      expect(host.inspectCount, 0);
      final invalid = await execute('act', {
        'grant': {'projectId': 'project-one'},
      });
      expect(invalid.ok, isFalse);
      expect(host.dispatchCount, 0);
    },
  );
  test(
    'direct call cannot borrow an existing native grant or caller-supplied authority',
    () async {
      await control.grantFromNative(host);
      final result =
          jsonDecode(await skill.methods['observe']!([]) as String) as Map;
      expect(result['error'], 'project_control_invocation_required');
      expect(host.inspectCount, 0);
    },
  );
  test(
    'structured act settles once and normal invocation closure retains native grant',
    () async {
      final grant = await control.grantFromNative(host);
      final observed = await observation();
      final pending = execute('act', action(observed));
      await waitDispatch();
      await control.acceptRuntimeResult(host, host.callback!, {
        'requestId': 'skill_request_01',
        'actionId': 'app.set',
        'status': 'applied',
        'stateVersion': 2,
        'result': {'value': 1},
      });
      expect((response(await pending)['data']! as Map)['status'], 'applied');
      await Future<void>.delayed(Duration.zero);
      expect(grant.isCurrent, isTrue);
      expect(host.fenceCount, 0);
      expect(
        (response(
              await execute('receipt', {'requestId': 'skill_request_01'}),
            )['data']!
            as Map)['status'],
        'applied',
      );
      expect(host.dispatchCount, 1);
    },
  );
  test(
    'revoked invocation while durable admission waits cannot dispatch an old action',
    () async {
      await control.grantFromNative(host);
      final observed = await observation();
      final gate = Completer<void>(), entered = Completer<void>();
      final held = db.transaction((tx) async {
        entered.complete();
        await gate.future;
      });
      await entered.future;
      final work = execute('act', action(observed));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      registry.invalidate();
      gate.complete();
      await held;
      final result = await work;
      expect(result.ok, isFalse);
      expect(result.observations, isEmpty);
      expect(host.dispatchCount, 0);
    },
  );
  test(
    'cancel after dispatch fences synchronously before drain; only original durable receipt remains queryable',
    () async {
      final grant = await control.grantFromNative(host);
      final observed = await observation();
      final work = execute('act', action(observed));
      await waitDispatch();
      registry.invalidate();
      final result = await work;
      expect(result.ok, isFalse);
      expect(result.observations, isEmpty);
      expect(host.fenceCount, 1);
      expect(await grant.onRevoked, 'invocation_cancelled');
      final original = await control.receipt(grant, 'skill_request_01');
      expect(original['status'], 'interrupted');
      expect(original['mayHaveApplied'], isTrue);
      expect(host.dispatchCount, 1);
    },
  );
}
