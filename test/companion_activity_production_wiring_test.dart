import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(() async {
    await appServices.reset();
  });

  test('catalog hides activity unless rollout is enforce', () async {
    final spec = SkillCatalog.byId('companion_activity');
    expect(spec, isNotNull);
    expect(spec!.isAvailable, isFalse);
    expect(SkillCatalog.available, isNot(contains(spec)));
    expect(SkillCatalog.defaultEnabled, isNot(contains(spec.id)));

    final clock = DateTime.utc(2026, 8, 30, 8);
    final flags = await MaasoFeatureFlagService(
      store: _MemoryFeatureFlagStore(),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.companionActivity: FeatureRolloutMode.enforce,
      },
      clock: () => clock,
    ).init();
    appServices.put(flags);
    await flags.assign(
      flag: MaasoFeatureFlag.companionActivity,
      mode: FeatureRolloutMode.enforce,
      revision: 1,
      expiresAt: clock.add(const Duration(hours: 1)),
    );

    expect(spec.isAvailable, isTrue);
    expect(SkillCatalog.available, contains(spec));
    expect(SkillCatalog.defaultEnabled, contains(spec.id));

    flags.setRuntimeMaximum(
      MaasoFeatureFlag.companionActivity,
      FeatureRolloutMode.shadow,
    );
    expect(spec.isAvailable, isFalse);
    expect(SkillCatalog.available, isNot(contains(spec)));
  });

  test(
    'account lifecycle mounts, fences, and drains activity before flags',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final mountStart = source.indexOf(
        'Future<AccountRuntimeLease> _mountAccountRuntime',
      );
      final mountEnd = source.indexOf(
        'Future<void> _disposeAccountRuntime',
        mountStart,
      );
      final mount = source.substring(mountStart, mountEnd);
      final flags = mount.indexOf('final featureFlags =');
      final activity = mount.indexOf('CompanionActivityService(');

      expect(flags, greaterThanOrEqualTo(0));
      expect(activity, greaterThan(flags));
      expect(mount, contains('SembastCompanionActivityStore('));
      expect(mount, contains('accountId: accountScope.accountDigest'));
      expect(mount, contains('facadeGeneration: mount.generation'));
      expect(mount, contains('MaasoFeatureFlag.companionActivity'));
      expect(mount, contains('rolloutGeneration:'));
      expect(mount, contains('featureFlags.authorityGeneration('));

      final drainStart = source.indexOf(
        'Future<void> _drainAccountRuntimeProducers',
      );
      final drainEnd = source.indexOf(
        'void _registerDefaultVadServices',
        drainStart,
      );
      final drain = source.substring(drainStart, drainEnd);
      final activityDrain = drain.indexOf("'companion_activity'");
      final flagDrain = drain.indexOf("'feature_flags'");
      expect(activityDrain, greaterThanOrEqualTo(0));
      expect(flagDrain, greaterThan(activityDrain));
      expect(drain, contains('companionActivityDrain'));
      expect(drain, contains('maybeFind<CompanionActivityService>()'));
    },
  );

  test(
    'runtime projections retain registrations but resnapshot availability',
    () {
      final runtime = File(
        'lib/src/features/agent/application/agent_runtime.dart',
      ).readAsStringSync();
      expect(runtime, contains('specs: SkillCatalog.all'));
      expect(runtime, contains('_synchronizeHostSkillAvailability()'));
      final home = File(
        'lib/src/features/home/application/home_controller.dart',
      ).readAsStringSync();
      expect(home, contains('specs: SkillCatalog.all'));
      expect(home, contains('_localHostSkills.availableManifests'));
      expect(
        File(
          'lib/src/features/skills/presentation/skills_page.dart',
        ).readAsStringSync(),
        contains('final installed = SkillCatalog.available'),
      );
    },
  );
}

final class _MemoryFeatureFlagStore implements MaasoFeatureFlagAssignmentStore {
  final Map<MaasoFeatureFlag, Map<String, Object?>> _rows =
      <MaasoFeatureFlag, Map<String, Object?>>{};

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      _rows.values.map(Map<String, Object?>.from).toList(growable: false);

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    _rows[assignment.flag] = assignment.toJson();
  }
}
