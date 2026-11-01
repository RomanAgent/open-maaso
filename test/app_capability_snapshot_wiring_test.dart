import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';

void main() {
  test('production resolver covers route, skill, and local runtime keys', () {
    final resolver = AppPlatformCapabilitySnapshotResolver(
      routeIds: AppRouteCatalog.destinations.map(
        (destination) => destination.id,
      ),
      skillIds: SkillCatalog.all.map((spec) => spec.id),
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

    expect(
      AppRouteCatalog.destinations.every(
        (destination) =>
            snapshot.decision(AppCapabilityKey.route(destination.id)) != null,
      ),
      isTrue,
    );
    expect(
      SkillCatalog.all.every(
        (spec) => snapshot.decision(AppCapabilityKey.skill(spec.id)) != null,
      ),
      isTrue,
    );
    for (final capability in <AppActionCapability>[
      AppActionCapability.onDeviceLlm,
      AppActionCapability.onDeviceSpeechModels,
      AppActionCapability.localSpeechRecognition,
    ]) {
      expect(
        snapshot.decision(AppCapabilityKey.platformAction(capability)),
        isNotNull,
      );
    }
    final requirements = SkillCatalog.capabilityRequirements;
    final bluetoothKey = AppCapabilityKey.platformAction(
      AppActionCapability.bluetooth,
    );
    expect(requirements['bluetooth'], contains(bluetoothKey));
    expect(requirements['ble_yoturetoys_projector'], contains(bluetoothKey));
  });

  test('main registers one permanent snapshot before runtime consumers', () {
    final source = File('lib/main.dart').readAsStringSync();
    final registration = source.indexOf('AppCapabilitySnapshotService(');
    final rolloutBinding = source.indexOf(
      'capabilitySnapshot.bindRollout(',
      registration,
    );

    expect(registration, greaterThanOrEqualTo(0));
    expect(
      source.indexOf('AppCapabilitySnapshotService(', registration + 1),
      -1,
    );
    expect(
      registration,
      lessThan(source.indexOf('MaasoAgentModeService().init()')),
    );
    expect(rolloutBinding, greaterThan(registration));
    expect(
      source.substring(registration, rolloutBinding),
      contains('permanent: true'),
    );
    expect(source, contains('routeIds: AppRouteCatalog.destinations.map('));
    expect(source, contains('skillIds: SkillCatalog.all.map('));
    expect(
      source,
      contains('skillRequirements: SkillCatalog.capabilityRequirements'),
    );
    expect(source, contains('skillAdmission: (skillId) =>'));
    expect(source, contains('changes: capabilityRollout.changes'));
    expect(source, contains('generation: () => capabilityRollout.generation'));
    expect(source, contains('activateRuntimeBoundary: (mount) {'));
    expect(source, contains('retireRuntimeBoundary: (accountGeneration) {'));
    expect(source, contains('capabilitySnapshot.activateAccount('));
    expect(source, contains('capabilitySnapshot.deactivateAccount('));
    expect(source, isNot(contains('capabilitySnapshot.bindAccountLifecycle(')));
    final activationStart = source.indexOf(
      'activateRuntimeBoundary: (mount) {',
    );
    final retirementStart = source.indexOf(
      'retireRuntimeBoundary: (accountGeneration) {',
      activationStart,
    );
    final activationWiring = source.substring(activationStart, retirementStart);
    expect(activationWiring, contains('mount.scope.accountDigest'));
    expect(activationWiring, isNot(contains('mount.scope.accountUuid')));
  });

  test('local skill and Skills UI boundaries consume the shared snapshot', () {
    final home = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();
    final skillsController = File(
      'lib/src/features/skills/application/skills_controller.dart',
    ).readAsStringSync();
    final skillsPage = File(
      'lib/src/features/skills/presentation/skills_page.dart',
    ).readAsStringSync();

    expect(home, contains('capabilitySnapshotService: _capabilitySnapshots'));
    expect(home, contains('capabilityKeysResolver: _localSkillCapabilityKeys'));
    expect(
      home,
      contains(
        RegExp(
          r'availabilityResolver:\s*\(manifest\)\s*=>\s*'
          r'conversationStyle\.isCurrent\s*&&\s*'
          r'_localSkillIsAvailable\(manifest\)',
        ),
      ),
    );
    expect(skillsController, contains('AppCapabilityKey.skill(id)'));
    expect(
      skillsPage,
      contains('ValueListenableBuilder<AppCapabilitySnapshot>'),
    );
    expect(
      skillsPage,
      contains('snapshot?.exposes(AppCapabilityKey.skill(spec.id))'),
    );
  });
}
