import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';

void main() {
  test('catalog declares only capabilities used by each skill handler', () {
    expect(SkillCatalog.byId('world_control'), isNull);
    expect(
      SkillCatalog.capabilityRequirements.containsKey('world_control'),
      isFalse,
    );
    expect(
      SkillCatalog.byId('face')!.requiredPlatformCapabilities,
      <AppActionCapability>{AppActionCapability.unityAvatar},
    );
    expect(
      SkillCatalog.byId('freeform_surface')!.requiredPlatformCapabilities,
      <AppActionCapability>{AppActionCapability.embeddedSurface},
    );

    expect(SkillCatalog.byId('avatar_motion_learning'), isNull);
    expect(
      SkillCatalog.capabilityRequirements.containsKey('avatar_motion_learning'),
      isFalse,
    );
  });

  test(
    'production requirements project into host-specific skill decisions',
    () {
      final linux = _snapshot(AppHostPlatform.linux);
      final web = _snapshot(AppHostPlatform.web);
      final macos = _snapshot(AppHostPlatform.macos);

      for (final skillId in <String>['face']) {
        expect(_allows(linux, skillId), isFalse);
        expect(_allows(web, skillId), isTrue);
        expect(_allows(macos, skillId), isTrue);
      }

      expect(_allows(linux, 'freeform_surface'), isFalse);
      expect(_allows(web, 'freeform_surface'), isFalse);
      expect(_allows(macos, 'freeform_surface'), isTrue);
      expect(_allows(linux, 'todo'), isTrue);
    },
  );

  test(
    'lazy registry omits and cannot activate unsupported catalog skills',
    () {
      final specs = <SkillSpec>[
        for (final id in <String>['face', 'freeform_surface', 'todo'])
          SkillCatalog.byId(id)!,
      ];
      final snapshots = _snapshotService(AppHostPlatform.linux, specs);
      final registry = LazyHostSkillRegistry(
        agentId: 'self',
        specs: specs,
        enabledSkillIds: specs.map((spec) => spec.id).toSet(),
        capabilitySnapshotService: snapshots,
      );
      addTearDown(registry.invalidate);
      addTearDown(snapshots.closeLifecycle);

      final descriptorNames = registry
          .descriptors()
          .map((descriptor) => descriptor.id)
          .toSet();
      expect(descriptorNames, <String>{'Todo'});

      expect(registry.isEnabled('WorldControl'), isFalse);
      expect(registry.descriptorFor('WorldControl'), isNull);
      expect(
        () => registry.activate('WorldControl'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'unknown_host_skill:WorldControl',
          ),
        ),
      );

      for (final skillName in <String>['FaceControl', 'FreeformSurface']) {
        expect(registry.isEnabled(skillName), isFalse);
        expect(
          () => registry.activate(skillName),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'host_skill_disabled:$skillName',
            ),
          ),
        );
      }
      expect(registry.activeCount, 0);
    },
  );
}

AppCapabilitySnapshot _snapshot(AppHostPlatform platform) {
  final specs = <SkillSpec>[
    for (final id in <String>['face', 'freeform_surface', 'todo'])
      SkillCatalog.byId(id)!,
  ];
  final service = _snapshotService(platform, specs);
  final snapshot = service.value;
  service.closeLifecycle();
  return snapshot;
}

AppCapabilitySnapshotService _snapshotService(
  AppHostPlatform platform,
  Iterable<SkillSpec> specs,
) => AppCapabilitySnapshotService(
  resolver: AppPlatformCapabilitySnapshotResolver(
    routeIds: const <String>{},
    skillIds: specs.map((spec) => spec.id),
    skillRequirements: SkillCatalog.capabilityRequirements,
  ),
  initialContext: AppCapabilitySnapshotContext(
    hostPlatform: platform,
    rolloutGeneration: 0,
  ),
);

bool _allows(AppCapabilitySnapshot snapshot, String skillId) =>
    snapshot.allows(AppCapabilityKey.skill(skillId), requireVisible: true);
