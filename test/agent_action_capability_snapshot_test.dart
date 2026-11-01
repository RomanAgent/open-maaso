import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/surface/surface_execution_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test('web rejects embedded Surface actions before presentation', () async {
    final snapshots = _snapshots(AppHostPlatform.web);
    addTearDown(snapshots.closeLifecycle);
    final surface = SurfaceRuntime();
    final executor = AgentActionExecutor(
      agentId: 'self',
      skillManager: SkillManager(),
      locale: AppLocale.en,
      surfaceRuntime: surface,
      capabilitySnapshotService: snapshots,
      speak: (_) async {},
    );

    final result = await executor.execute(
      AgentActionEnvelope.parse('''
{
  "reply":"",
  "actions":[{
    "type":"surface.show",
    "surface":{
      "title":"Capability card",
      "experienceType":"utility",
      "kind":"card",
      "rendering":"dom",
      "html":"<main><p>Ready</p></main>",
      "css":"",
      "js":"",
      "manifest":{"events":[],"actions":[]}
    }
  }]
}
'''),
    );

    expect(
      result.errors.single,
      contains('capability_unavailable:surface.show'),
    );
    expect(result.errors.single, contains('unsupported_host_platform'));
    expect(surface.isVisible.value, isFalse);
  });

  test(
    'surface show cannot cross generation when persistence starts',
    () async {
      final snapshots = _snapshots(AppHostPlatform.macos);
      addTearDown(snapshots.closeLifecycle);
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'capability_surface_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      final authorization = _surfaceAuthorization(
        SurfaceExperienceType.utility,
      );
      final surface = SurfaceRuntime();
      final executor = AgentActionExecutor(
        agentId: 'self',
        skillManager: authorization.manager,
        locale: AppLocale.en,
        surfaceRuntime: surface,
        surfaceExecutionGrant: authorization.grant,
        expectedAppletScopeKey: authorization.scopeKey,
        capabilitySnapshotService: snapshots,
        requirePersistedSurface: true,
        confirmAppletSave: (_) async => true,
        onSurfacePersistenceStarted: () {
          snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
        },
        speak: (_) async {},
      );

      final result = await executor.execute(
        AgentActionEnvelope.parse('''
{
  "reply":"",
  "actions":[{
    "type":"surface.show",
    "surface":{
      "id":"capability-persistence-fence",
      "title":"Capability card",
      "experienceType":"utility",
      "kind":"card",
      "rendering":"dom",
      "html":"<main><p>Ready</p></main>",
      "css":"",
      "js":"",
      "manifest":{"events":[],"actions":[]}
    }
  }]
}
'''),
      );

      expect(result.errors.single, contains('capability_snapshot_stale'));
      expect(surface.isVisible.value, isFalse);
      expect(await database.getAllWidgets(), isEmpty);
    },
  );

  test(
    'generation change before the next action rejects the pinned lease',
    () async {
      final snapshots = _snapshots(AppHostPlatform.macos);
      addTearDown(snapshots.closeLifecycle);
      final spoken = <String>[];
      final executor = AgentActionExecutor(
        agentId: 'self',
        skillManager: SkillManager(),
        locale: AppLocale.en,
        capabilitySnapshotService: snapshots,
        speak: (text) async {
          spoken.add(text);
          snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
        },
      );

      final result = await executor.execute(
        AgentActionEnvelope(
          reply: '',
          actions: <AgentAction>[
            AgentAction(
              type: 'voice.speak',
              data: const <String, Object?>{'text': 'before refresh'},
            ),
            AgentAction(
              type: 'avatar.act',
              data: const <String, Object?>{'mood': 'happy', 'gesture': 'wave'},
            ),
          ],
        ),
      );

      expect(spoken, <String>['before refresh']);
      expect(result.errors.single, contains('capability_snapshot_stale'));
    },
  );

  test(
    'unmapped actions cannot continue after generation invalidation',
    () async {
      final snapshots = _snapshots(AppHostPlatform.macos);
      addTearDown(snapshots.closeLifecycle);
      final spoken = <String>[];
      final executor = AgentActionExecutor(
        agentId: 'self',
        skillManager: SkillManager(),
        locale: AppLocale.en,
        capabilitySnapshotService: snapshots,
        speak: (text) async {
          spoken.add(text);
          snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
        },
      );

      final result = await executor.execute(
        AgentActionEnvelope(
          reply: '',
          actions: <AgentAction>[
            AgentAction(
              type: 'voice.speak',
              data: const <String, Object?>{'text': 'first'},
            ),
            AgentAction(
              type: 'emotion.set',
              data: const <String, Object?>{'emotion': 'happy'},
            ),
            AgentAction(
              type: 'voice.speak',
              data: const <String, Object?>{'text': 'second'},
            ),
          ],
        ),
      );

      expect(spoken, <String>['first']);
      expect(result.errors, hasLength(2));
      expect(
        result.errors,
        everyElement(contains('capability_snapshot_stale')),
      );
    },
  );

  test('implicit reply rechecks generation after automatic reaction', () async {
    final snapshots = _snapshots(AppHostPlatform.macos);
    addTearDown(snapshots.closeLifecycle);
    final spoken = <String>[];
    final executor = AgentActionExecutor(
      agentId: 'self',
      skillManager: SkillManager(),
      locale: AppLocale.en,
      capabilitySnapshotService: snapshots,
      avatarBehaviorDirector: _RefreshingAvatarBehaviorDirector(snapshots),
      speak: spoken.add,
    );

    final result = await executor.execute(
      const AgentActionEnvelope(reply: 'must not speak', actions: []),
    );

    expect(spoken, isEmpty);
    expect(result.errors.single, contains('capability_snapshot_stale'));
  });
}

AppCapabilitySnapshotService _snapshots(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: const <String>{},
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );

final class _RefreshingAvatarBehaviorDirector extends AvatarBehaviorDirector {
  _RefreshingAvatarBehaviorDirector(this.snapshots);

  final AppCapabilitySnapshotService snapshots;

  @override
  Future<AvatarBehaviorResult> autoReact(
    AvatarAutoReactionContext context,
  ) async {
    snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
    return const AvatarBehaviorResult(applied: false, reason: 'test');
  }
}

({SkillManager manager, SurfaceExecutionGrant grant, String scopeKey})
_surfaceAuthorization(SurfaceExperienceType experienceType) {
  final registry = LazyHostSkillRegistry(
    agentId: 'self',
    specs: SkillCatalog.all,
    enabledSkillIds: const <String>{'freeform_surface'},
  );
  final descriptor = registry.descriptorFor('FreeformSurface')!;
  final hostGrant = registry.issueGrant(
    TurnSkillGrant.bounded(
      rankedDescriptors: <SkillDescriptor>[descriptor],
      maxSkills: 1,
      promptBudget: 4096,
    ),
  );
  final manager = SkillManager()
    ..registerSkill(hostGrant.activatedSkills.single);
  final scopeKey = AppletLocalOwnership.currentScopeKey();
  return (
    manager: manager,
    scopeKey: scopeKey,
    grant: SurfaceExecutionGrant.issue(
      executableHostGrant: hostGrant,
      agentId: 'self',
      appletScopeKey: scopeKey,
      experienceType: experienceType,
    ),
  );
}
