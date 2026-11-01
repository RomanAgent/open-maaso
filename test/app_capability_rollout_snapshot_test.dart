import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout_service.dart';

void main() {
  test('rollout policy atomically hides and revokes AppControl', () async {
    final rollout = AgentCapabilityRolloutService(
      initial: const AgentCapabilityRollout(
        requestLazyHostActivation: true,
        requestPageSkillDefaults: true,
        requestPageAgentControl: true,
      ),
    );
    final snapshots = AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: const <String>{},
        skillIds: const <String>{'app_control', 'app_navigate'},
        skillAdmission: (skillId) =>
            rollout.current.lazyHostActivationEnabled &&
            (skillId != 'app_control' ||
                rollout.current.pageAgentControlEnabled),
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.macos,
        rolloutGeneration: rollout.generation,
      ),
    );
    snapshots.bindRollout(
      changes: rollout.changes,
      generation: () => rollout.generation,
    );
    final appControlKey = AppCapabilityKey.skill('app_control');
    final oldLease = snapshots.acquireLease(<AppCapabilityKey>[
      appControlKey,
    ], requireVisible: true).lease!;

    rollout.update(AgentCapabilityRollout.lazyActivationOnly);
    await expectLater(oldLease.whenInvalidated, completes);

    final decision = snapshots.value.decision(appControlKey)!;
    expect(decision.exposure, AppCapabilityExposure.hidden);
    expect(decision.admission, AppCapabilityAdmission.denied);
    expect(decision.readiness, AppCapabilityReadiness.ready);
    expect(decision.reasonCodes, contains('skill_policy_denied'));
    expect(
      snapshots.acquireLease(<AppCapabilityKey>[
        appControlKey,
      ], requireVisible: true).isGranted,
      isFalse,
    );
    expect(
      snapshots.value.allows(
        AppCapabilityKey.skill('app_navigate'),
        requireVisible: true,
      ),
      isTrue,
    );

    snapshots.closeLifecycle();
    rollout.closeLifecycle();
  });

  test('skill policy exceptions fail closed without partial publication', () {
    final resolver = AppPlatformCapabilitySnapshotResolver(
      routeIds: const <String>{},
      skillIds: const <String>{'broken'},
      skillAdmission: (_) => throw StateError('policy unavailable'),
    );
    final snapshot = AppCapabilitySnapshot.materialize(
      generation: 0,
      draft: resolver.resolve(
        AppCapabilitySnapshotContext(
          hostPlatform: AppHostPlatform.macos,
          rolloutGeneration: 0,
        ),
      ),
    );

    final decision = snapshot.decision(AppCapabilityKey.skill('broken'))!;
    expect(decision.isVisible, isFalse);
    expect(decision.admission, AppCapabilityAdmission.denied);
    expect(decision.reasonCodes, contains('skill_policy_denied'));
  });

  test('hardware skill readiness follows the platform capability matrix', () {
    final resolver = AppPlatformCapabilitySnapshotResolver(
      routeIds: const <String>{},
      skillIds: const <String>{'bluetooth', 'ble_yoturetoys_projector'},
      skillRequirements: SkillCatalog.capabilityRequirements,
    );

    AppCapabilitySnapshot snapshotFor(AppHostPlatform platform) =>
        AppCapabilitySnapshot.materialize(
          generation: 0,
          draft: resolver.resolve(
            AppCapabilitySnapshotContext(
              hostPlatform: platform,
              rolloutGeneration: 0,
            ),
          ),
        );

    final web = snapshotFor(AppHostPlatform.web);
    expect(
      web.allows(AppCapabilityKey.skill('bluetooth'), requireVisible: true),
      isFalse,
    );
    expect(
      web
          .decision(AppCapabilityKey.skill('ble_yoturetoys_projector'))!
          .reasonCodes,
      contains('unsupported_host_platform'),
    );

    final macos = snapshotFor(AppHostPlatform.macos);
    expect(
      macos.allows(AppCapabilityKey.skill('bluetooth'), requireVisible: true),
      isTrue,
    );
    expect(
      macos.allows(
        AppCapabilityKey.skill('ble_yoturetoys_projector'),
        requireVisible: true,
      ),
      isTrue,
    );
  });
}
