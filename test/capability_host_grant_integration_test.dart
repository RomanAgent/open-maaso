import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill_structured_action_schema.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test('snapshot removal hides skill and blocks stale descriptor', () {
    final resolver = _MutableSkillResolver(<String>{'alpha_catalog'});
    final snapshots = AppCapabilitySnapshotService(
      resolver: resolver,
      initialContext: _snapshotContext(),
    );
    addTearDown(snapshots.closeLifecycle);
    var created = 0;
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: <SkillSpec>[
        _spec(
          id: 'alpha_catalog',
          skillName: 'AlphaHost',
          factory: (_) {
            created += 1;
            return _FenceSkill('AlphaHost');
          },
        ),
      ],
      capabilitySnapshotService: snapshots,
    );

    final descriptor = registry.descriptorFor('AlphaHost')!;

    resolver.skillIds.clear();
    snapshots.refresh(snapshots.context);

    expect(registry.descriptorFor('AlphaHost'), isNull);
    expect(registry.isEnabled('AlphaHost'), isFalse);
    expect(() => registry.activate('AlphaHost'), throwsStateError);
    expect(
      registry.issueGrant(_promptGrant(descriptor)),
      same(ExecutableHostGrant.none),
    );
    expect(created, 0);
    expect(registry.activeCount, 0);
  });

  test('explicit snapshot wins and omitted injection uses appServices', () {
    final singleton = _snapshotService(skillIds: const <String>{});
    appServices.put<AppCapabilitySnapshotService>(singleton);
    final explicit = _snapshotService(
      skillIds: const <String>{'alpha_catalog'},
    );
    addTearDown(explicit.closeLifecycle);
    final specs = <SkillSpec>[
      _spec(id: 'alpha_catalog', skillName: 'AlphaHost'),
    ];

    final inherited = LazyHostSkillRegistry(agentId: 'inherited', specs: specs);
    final overridden = LazyHostSkillRegistry(
      agentId: 'overridden',
      specs: specs,
      capabilitySnapshotService: explicit,
    );

    expect(inherited.descriptorFor('AlphaHost'), isNull);
    expect(inherited.isEnabled('AlphaHost'), isFalse);
    expect(overridden.descriptorFor('AlphaHost'), isNotNull);
    expect(overridden.isEnabled('AlphaHost'), isTrue);
  });

  test(
    'snapshot generation invalidates host grant and prompt cache key',
    () async {
      final snapshots = _snapshotService(
        skillIds: const <String>{'alpha_catalog'},
      );
      addTearDown(snapshots.closeLifecycle);
      var created = 0;
      final registry = LazyHostSkillRegistry(
        agentId: 'agent-test',
        specs: <SkillSpec>[
          _spec(
            id: 'alpha_catalog',
            skillName: 'AlphaHost',
            factory: (_) {
              created += 1;
              return _FenceSkill('AlphaHost');
            },
          ),
        ],
        capabilitySnapshotService: snapshots,
      );
      final descriptor = registry.descriptorFor('AlphaHost')!;
      final grant = registry.issueGrant(_promptGrant(descriptor));
      final originalSkill = grant.activatedSkills.single;
      final tool = HostSkillRoutingManifest.nativeToolName('AlphaHost', 'run');
      final originalCacheKey = grant.cacheKey;
      final invalidated = expectLater(grant.whenInvalidated, completes);

      expect(grant.isCurrent, isTrue);
      expect(created, 1);
      expect(originalCacheKey, contains(snapshots.value.cacheKey));

      snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
      await invalidated;

      expect(grant.isCurrent, isFalse);
      expect(grant.cacheKey, 'stale');
      expect(grant.authorize(agentId: 'agent-test', tool: tool), isNull);

      expect(
        registry.issueGrant(_promptGrant(descriptor)),
        same(ExecutableHostGrant.none),
        reason: 'snapshot refresh clears descriptor provenance',
      );
      final freshDescriptor = registry.descriptorFor('AlphaHost')!;
      expect(freshDescriptor, isNot(same(descriptor)));
      final fresh = registry.issueGrant(_promptGrant(freshDescriptor));
      expect(fresh.isCurrent, isTrue);
      expect(fresh.activatedSkills.single, same(originalSkill));
      expect(created, 1);
      expect(fresh.cacheKey, isNot(originalCacheKey));
    },
  );

  test('grant materialization fails closed when its lease is revoked', () {
    final resolver = _MutableSkillResolver(<String>{
      'alpha_catalog',
      'beta_catalog',
    });
    final snapshots = AppCapabilitySnapshotService(
      resolver: resolver,
      initialContext: _snapshotContext(),
    );
    addTearDown(snapshots.closeLifecycle);
    var alphaCreated = 0;
    var betaCreated = 0;
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: <SkillSpec>[
        _spec(
          id: 'alpha_catalog',
          skillName: 'AlphaHost',
          factory: (_) {
            alphaCreated += 1;
            resolver.skillIds.clear();
            snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
            return _FenceSkill('AlphaHost');
          },
        ),
        _spec(
          id: 'beta_catalog',
          skillName: 'BetaHost',
          factory: (_) {
            betaCreated += 1;
            return _FenceSkill('BetaHost');
          },
        ),
      ],
      capabilitySnapshotService: snapshots,
    );
    final descriptors = registry.descriptors();

    final grant = registry.issueGrant(
      TurnSkillGrant.bounded(
        rankedDescriptors: descriptors,
        maxSkills: 2,
        promptBudget: 2048,
      ),
    );

    expect(grant, same(ExecutableHostGrant.none));
    expect(alphaCreated, 1);
    expect(betaCreated, 0);
    expect(registry.activeCount, 0);
  });

  test('disable then re-enable preserves SkillManager owner identity', () {
    final resolver = _MutableSkillResolver(<String>{'alpha_catalog'});
    final snapshots = AppCapabilitySnapshotService(
      resolver: resolver,
      initialContext: _snapshotContext(),
    );
    addTearDown(snapshots.closeLifecycle);
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: <SkillSpec>[_spec(id: 'alpha_catalog', skillName: 'AlphaHost')],
      capabilitySnapshotService: snapshots,
    );
    final firstDescriptor = registry.descriptorFor('AlphaHost')!;
    final firstGrant = registry.issueGrant(_promptGrant(firstDescriptor));
    final manager = SkillManager()
      ..registerSkill(firstGrant.activatedSkills.single);

    resolver.skillIds.clear();
    snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
    expect(registry.descriptorFor('AlphaHost'), isNull);
    expect(firstGrant.isCurrent, isFalse);

    resolver.skillIds.add('alpha_catalog');
    snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 2));
    final freshDescriptor = registry.descriptorFor('AlphaHost')!;
    final freshGrant = registry.issueGrant(_promptGrant(freshDescriptor));

    expect(freshGrant.isCurrent, isTrue);
    expect(
      freshGrant.activatedSkills.single,
      same(manager.findSkill('AlphaHost')),
    );
  });

  test(
    'executor revalidates snapshot lease immediately before handler',
    () async {
      final snapshots = _snapshotService(
        skillIds: const <String>{'fenced_catalog'},
      );
      addTearDown(snapshots.closeLifecycle);
      late final _FenceSkill skill;
      skill = _FenceSkill(
        'FencedHost',
        onSchemaRead: (readCount) {
          if (readCount == 3) {
            snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
          }
        },
      );
      final registry = LazyHostSkillRegistry(
        agentId: 'agent-test',
        specs: <SkillSpec>[
          _spec(
            id: 'fenced_catalog',
            skillName: 'FencedHost',
            factory: (_) => skill,
          ),
        ],
        capabilitySnapshotService: snapshots,
      );
      final descriptor = registry.descriptorFor('FencedHost')!;
      final grant = registry.issueGrant(_promptGrant(descriptor));
      final activated = grant.activatedSkills.single as _FenceSkill;
      final manager = SkillManager()..registerSkill(activated);
      final tool = SkillManager.nativeToolName(activated, 'run');
      final executor = AgentActionExecutor(
        agentId: 'agent-test',
        skillManager: manager,
        locale: AppLocale.en,
        executableHostGrant: grant,
      );

      final result = await executor.execute(
        AgentActionEnvelope(
          reply: '',
          actions: <AgentAction>[
            AgentAction(
              type: 'skill.call',
              data: <String, Object?>{
                'tool': tool,
                'args': const <String, Object?>{},
              },
            ),
          ],
        ),
      );

      expect(skill.schemaReadCount, 3);
      expect(grant.isCurrent, isFalse);
      expect(result.errors.single, contains('skill_not_granted'));
      expect(skill.callCount, 0);
    },
  );
}

AppCapabilitySnapshotService _snapshotService({
  required Set<String> skillIds,
}) => AppCapabilitySnapshotService(
  resolver: AppPlatformCapabilitySnapshotResolver(
    routeIds: const <String>{},
    skillIds: skillIds,
  ),
  initialContext: _snapshotContext(),
);

AppCapabilitySnapshotContext _snapshotContext() => AppCapabilitySnapshotContext(
  hostPlatform: AppHostPlatform.macos,
  rolloutGeneration: 0,
);

TurnSkillGrant _promptGrant(SkillDescriptor descriptor) =>
    TurnSkillGrant.bounded(
      rankedDescriptors: <SkillDescriptor>[descriptor],
      maxSkills: 1,
      promptBudget: 1024,
    );

SkillSpec _spec({
  required String id,
  required String skillName,
  AgentSkill Function(String agentId)? factory,
}) => SkillSpec(
  id: id,
  name: id,
  description: id,
  icon: Icons.extension_rounded,
  color: Colors.blue,
  category: SkillCategory.core,
  factory: factory ?? (_) => _FenceSkill(skillName),
  hostRouting: HostSkillRoutingManifest(
    skillName: skillName,
    summary: '$skillName routing summary.',
    methods: const <String>['run'],
  ),
);

final class _FenceSkill extends AgentSkill
    implements StructuredActionPromptSchemaProvider {
  _FenceSkill(this._skillName, {this.onSchemaRead});

  final String _skillName;
  final void Function(int readCount)? onSchemaRead;
  int schemaReadCount = 0;
  int callCount = 0;

  @override
  String get skillName => _skillName;

  @override
  String get description => 'Capability host grant test skill';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        'run': (_) {
          callCount += 1;
          return '{}';
        },
      };

  @override
  StructuredActionPromptSchemas get structuredActionPromptSchemas {
    schemaReadCount += 1;
    onSchemaRead?.call(schemaReadCount);
    return StructuredActionPromptSchemas(const <String, Map<String, dynamic>>{
      'run': <String, dynamic>{'type': 'object', 'additionalProperties': false},
    });
  }
}

final class _MutableSkillResolver implements AppCapabilitySnapshotResolver {
  _MutableSkillResolver(this.skillIds);

  final Set<String> skillIds;

  @override
  AppCapabilitySnapshotDraft resolve(AppCapabilitySnapshotContext context) =>
      AppCapabilitySnapshotDraft(
        context: context,
        decisions: <AppCapabilityDecision>[
          for (final id in skillIds)
            AppCapabilityDecision.available(AppCapabilityKey.skill(id)),
        ],
      );
}
