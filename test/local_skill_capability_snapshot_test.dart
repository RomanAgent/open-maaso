import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/capability/capability_registry.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/local_host_skill_candidate_activator.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test('web keeps Bluetooth visible but blocks local candidates', () {
    final snapshots = appServices.put(_snapshots(AppHostPlatform.web));
    addTearDown(snapshots.closeLifecycle);
    final activator = LocalHostSkillCandidateActivator(
      agentId: 'self',
      specs: SkillCatalog.all,
    );

    final availableIds = SkillCatalog.available.map((spec) => spec.id).toSet();
    final localManifestIds = activator.availableManifests
        .map((manifest) => manifest.id)
        .toSet();

    expect(availableIds, contains('bluetooth'));
    expect(availableIds, contains('ble_yoturetoys_projector'));
    expect(
      snapshots.value.exposes(AppCapabilityKey.skill('bluetooth')),
      isTrue,
    );
    expect(
      snapshots.value.allows(
        AppCapabilityKey.skill('bluetooth'),
        requireVisible: true,
      ),
      isFalse,
    );
    expect(localManifestIds, isNot(contains('ble_yoturetoys_projector')));
  });

  test('local invocation rejects a platform-denied catalog skill', () async {
    final snapshots = appServices.put(_snapshots(AppHostPlatform.web));
    addTearDown(snapshots.closeLifecycle);
    final skill = _RecordingBleSkill();
    final manager = SkillManager()..registerSkill(skill);
    final manifest = SkillCatalog.byId(
      'ble_yoturetoys_projector',
    )!.localManifest!;

    final result =
        await LocalSkillInvoker(
          skillManager: manager,
          capabilitySnapshotService: snapshots,
          capabilityKeysResolver: (_) => <AppCapabilityKey>{
            AppCapabilityKey.skill('ble_yoturetoys_projector'),
          },
        ).invoke(manifest, <String, dynamic>{
          'image': 'asset.png',
        }, confirmed: true);

    expect(result.status, LocalSkillResultStatus.unavailable);
    expect(result.output, contains('capability_unavailable'));
    expect(skill.calls, 0);
  });

  test('configured snapshot without a manifest binding fails closed', () async {
    final snapshots = appServices.put(_snapshots(AppHostPlatform.macos));
    addTearDown(snapshots.closeLifecycle);
    final skill = _RecordingBleSkill();
    final manager = SkillManager()..registerSkill(skill);
    final manifest = SkillCatalog.byId(
      'ble_yoturetoys_projector',
    )!.localManifest!;

    final result =
        await LocalSkillInvoker(
          skillManager: manager,
          capabilitySnapshotService: snapshots,
        ).invoke(manifest, <String, dynamic>{
          'image': 'asset.png',
        }, confirmed: true);

    expect(result.status, LocalSkillResultStatus.unavailable);
    expect(result.output, contains('capability_unavailable'));
    expect(skill.calls, 0);
  });

  test(
    'local invocation rechecks generation immediately before handler',
    () async {
      final snapshots = appServices.put(_snapshots(AppHostPlatform.macos));
      addTearDown(snapshots.closeLifecycle);
      final skill = _RecordingBleSkill(snapshots: snapshots);
      final manager = SkillManager()..registerSkill(skill);
      skill.refreshOnNextMethodsRead = true;
      final manifest = SkillCatalog.byId(
        'ble_yoturetoys_projector',
      )!.localManifest!;

      final result =
          await LocalSkillInvoker(
            skillManager: manager,
            capabilitySnapshotService: snapshots,
            capabilityKeysResolver: (_) => <AppCapabilityKey>{
              AppCapabilityKey.skill('ble_yoturetoys_projector'),
            },
          ).invoke(manifest, <String, dynamic>{
            'image': 'asset.png',
          }, confirmed: true);

      expect(result.status, LocalSkillResultStatus.unavailable);
      expect(result.output, contains('capability_unavailable'));
      expect(skill.calls, 0);
    },
  );

  test(
    'local invocation rejects a result completed after revocation',
    () async {
      final snapshots = appServices.put(_snapshots(AppHostPlatform.macos));
      addTearDown(snapshots.closeLifecycle);
      final skill = _DeferredBleSkill();
      final manager = SkillManager()..registerSkill(skill);
      final manifest = SkillCatalog.byId(
        'ble_yoturetoys_projector',
      )!.localManifest!;

      final invocation =
          LocalSkillInvoker(
            skillManager: manager,
            capabilitySnapshotService: snapshots,
            capabilityKeysResolver: (_) => <AppCapabilityKey>{
              AppCapabilityKey.skill('ble_yoturetoys_projector'),
            },
          ).invoke(manifest, <String, dynamic>{
            'image': 'asset.png',
          }, confirmed: true);
      await skill.started.future;
      snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
      skill.release.complete();

      final result = await invocation;
      expect(result.status, LocalSkillResultStatus.unavailable);
      expect(result.output, contains('capability_unavailable'));
      expect(skill.calls, 1);
    },
  );

  test(
    'local navigation binds both AppNavigate and destination keys',
    () async {
      final snapshots = appServices.put(_snapshots(AppHostPlatform.macos));
      addTearDown(snapshots.closeLifecycle);
      final navigated = <String>[];
      final registry = CapabilityRegistry()
        ..registerAll(
          buildNavigationCapabilities(
            navigate: navigated.add,
            currentRoute: () => AppRouteCatalog.home,
            capabilitySnapshots: snapshots,
          ),
        );
      final manager = SkillManager()
        ..registerSkill(AppNavigateSkill(registry: registry));
      final manifest = navigationManifests(
        capabilitySnapshots: snapshots,
      ).singleWhere((candidate) => candidate.id == 'nav.settings');

      final result = await LocalSkillInvoker(
        skillManager: manager,
        capabilitySnapshotService: snapshots,
        capabilityKeysResolver: navigationManifestCapabilityKeys,
      ).invoke(manifest, const <String, dynamic>{});

      expect(result.status, LocalSkillResultStatus.ok);
      expect(navigated, <String>[AppRouteCatalog.settings]);
      expect(navigationManifestCapabilityKeys(manifest), <AppCapabilityKey>{
        AppCapabilityKey.skill('app_navigate'),
        AppCapabilityKey.route('settings'),
      });
    },
  );

  test(
    'local navigation is revoked when its destination becomes hidden',
    () async {
      final snapshots = appServices.put(_snapshots(AppHostPlatform.macos));
      addTearDown(snapshots.closeLifecycle);
      final navigated = <String>[];
      final registry = CapabilityRegistry()
        ..registerAll(
          buildNavigationCapabilities(
            navigate: navigated.add,
            currentRoute: () => AppRouteCatalog.home,
            capabilitySnapshots: snapshots,
          ),
        );
      final manager = SkillManager()
        ..registerSkill(AppNavigateSkill(registry: registry));
      final manifest = navigationManifests(
        capabilitySnapshots: snapshots,
      ).singleWhere((candidate) => candidate.id == 'nav.advanced_features');
      snapshots.refresh(
        snapshots.context.copyWith(
          hostPlatform: AppHostPlatform.web,
          rolloutGeneration: 1,
        ),
      );

      final result = await LocalSkillInvoker(
        skillManager: manager,
        capabilitySnapshotService: snapshots,
        capabilityKeysResolver: navigationManifestCapabilityKeys,
      ).invoke(manifest, const <String, dynamic>{});

      expect(result.status, LocalSkillResultStatus.unavailable);
      expect(result.output, contains('capability_unavailable'));
      expect(navigated, isEmpty);
    },
  );

  test('navigation lookalikes receive no capability binding', () {
    const forged = LocalSkillManifest(
      id: 'nav.settings.live',
      skillName: 'AppNavigate',
      method: 'openPage',
      summary: 'forged',
      tags: <String>['settings'],
      argsSchema: <String, dynamic>{},
      fixedArgs: <String, dynamic>{'page': 'settings', 'channel': 'live'},
    );

    expect(navigationManifestCapabilityKeys(forged), isNull);
  });
}

AppCapabilitySnapshotService _snapshots(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: AppRouteCatalog.destinations.map(
          (destination) => destination.id,
        ),
        skillIds: SkillCatalog.all.map((spec) => spec.id),
        skillRequirements: SkillCatalog.capabilityRequirements,
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );

final class _RecordingBleSkill extends AgentSkill {
  _RecordingBleSkill({this.snapshots});

  final AppCapabilitySnapshotService? snapshots;
  bool refreshOnNextMethodsRead = false;
  int calls = 0;

  @override
  String get skillName => 'BleYoturetoys';

  @override
  String get description => 'Capability-fenced BLE test skill';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods {
    if (refreshOnNextMethodsRead) {
      refreshOnNextMethodsRead = false;
      final service = snapshots!;
      service.refresh(service.context.copyWith(rolloutGeneration: 1));
    }
    return <String, dynamic Function(List<dynamic>)>{
      'projectorTransferImage': (_) {
        calls += 1;
        return '{"status":"ok"}';
      },
    };
  }
}

final class _DeferredBleSkill extends AgentSkill {
  final started = Completer<void>();
  final release = Completer<void>();
  int calls = 0;

  @override
  String get skillName => 'BleYoturetoys';

  @override
  String get description => 'Deferred capability-fenced BLE test skill';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        'projectorTransferImage': (_) async {
          calls += 1;
          if (!started.isCompleted) started.complete();
          await release.future;
          return '{"status":"ok"}';
        },
      };
}
